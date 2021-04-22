# cython: language_level=3, boundscheck=False
# distutils: language = c++
"""Bridge between Python file-like objects and GDAL VSI.

The functionality provided in this interface is made possible thanks to GDAL's
Plugin infrastructure. You can find more information about this below and in
GDAL's documentation here:

https://gdal.org/api/cpl.html#structVSIFilesystemPluginCallbacksStruct

.. note::

    Parts of GDAL's plugin interface use C++ features/definitions. For
    that reason this module must be compiled as C++.

The high-level idea of the plugin interface is to define a series of callbacks
for the operations GDAL may need to perform. There are two types of operations:
filesystem and file. The filesystem operations cover things like opening a file,
making directories, renaming files, etc. The file operations involve things like
reading from the file, seeking to a specific position, and getting the current
position in the file.

Filesystem Handling
*******************

This plugin currently only defines the "open" callback. The other features are
either not needed or have usable default implementations.

The entire filesystem's state is stored in a global dictionary mapping
in-memory GDAL filenames to :class:`~rasterio._pyvsi.PyVSIFileBase` objects.

File Handling
*************

This plugin implements the bare minimum for reading from an open file-like
object. It does this by mapping GDAL's function calls (ex. read, seek) to
the corresponding method call on the file-like object.

"""

include "gdal.pxi"

import logging
from uuid import uuid4

from rasterio._base cimport open_dataset
from rasterio._err import (
    GDALError, CPLE_OpenFailedError, CPLE_IllegalArgError, CPLE_BaseError, CPLE_AWSObjectNotFoundError)

from libc.stdio cimport printf
from libc.string cimport memcpy

from rasterio._err cimport exc_wrap_int, exc_wrap_pointer, exc_wrap_vsilfile

log = logging.getLogger(__name__)

gdal33_version_checked = False
gdal33_version_met = False


# NOTE: This has to be defined outside of gdal.pxi or other C extensions will
# try to compile C++ only code included in this header.
cdef extern from "cpl_vsi_virtual.h":
    cdef cppclass VSIFileManager:
        @staticmethod
        void* GetHandler(const char*)


# Prefix for all in-memory paths used by GDAL's VSI system
# Except for errors and log messages this shouldn't really be seen by the user
cdef str FILESYSTEM_PREFIX = "/vsipythonfilelike/"
cdef bytes FILESYSTEM_PREFIX_BYTES = FILESYSTEM_PREFIX.encode("ascii")
# This is global state for the Python filesystem plugin. It currently only
# contains path -> PyVSIFileBase (or subclass) instances. This is used by
# the plugin to determine what "files" exist on "disk".
# Currently the only way to "create" a file in the filesystem is to add
# an entry to this dictionary. GDAL will then Open the path later.
cdef _FILESYSTEM_INFO = {}

def _delete_dataset_if_exists(path):

    """Delete a dataset if it already exists.  This operates at a lower
    level than a:

        if rasterio.shutil.exists(path):
            rasterio.shutil.delete(path)

    and can take some shortcuts.

    Parameters
    ----------
    path : str
        Dataset path.
    """

    cdef GDALDatasetH h_dataset = NULL
    cdef GDALDriverH h_driver = NULL
    cdef const char *path_c = NULL

    try:
        h_dataset = open_dataset(path, 0x40, None, None, None)
    except (CPLE_OpenFailedError, CPLE_AWSObjectNotFoundError) as exc:
        log.debug(
            "Skipped delete for overwrite. Dataset does not exist: %r", path)
    else:
        h_driver = GDALGetDatasetDriver(h_dataset)
        GDALClose(h_dataset)
        h_dataset = NULL

        if h_driver != NULL:
            path_b = path.encode("utf-8")
            path_c = path_b
            with nogil:
                err = GDALDeleteDataset(h_driver, path_c)
            exc_wrap_int(err)
    finally:
        if h_dataset != NULL:
            GDALClose(h_dataset)

## Filesystem Functions

cdef int pyvsi_stat(void *pUserData, const char *pszFilename, VSIStatBufL *pStatBuf, int nFlags) with gil:
    # Optional
    printf("stat\n")


cdef int pyvsi_unlink(void *pUserData, const char *pszFilename) with gil:
    # Optional
    printf("unlink\n")


cdef int pyvsi_rename(void *pUserData, const char *oldpath, const char *newpath) with gil:
    # Optional
    printf("rename\n")


cdef int pyvsi_mkdir(void *pUserData, const char *pszDirname, long nMode) with gil:
    # Optional
    printf("mkdir\n")


cdef int pyvsi_rmdir(void *pUserData, const char *pszDirname) with gil:
    # Optional
    printf("rmdir\n")


cdef char** pyvsi_read_dir(void *pUserData, const char *pszDirname, int nMaxFiles) with gil:
    # Optional
    printf("read_dir\n")


cdef char** pyvsi_siblings_files(void *pUserData, const char *pszDirname) with gil:
    # Optional (GDAL 3.2+)
    printf("siblings_files\n")


cdef void* pyvsi_open(void *pUserData, const char *pszFilename, const char *pszAccess) with gil:
    """Access existing open file-like object in the virtual filesystem.
    
    This function is mandatory in the GDAL Filesystem Plugin API.
    
    """
    cdef object file_wrapper

    if pszAccess != b"r" and pszAccess != b"rb":
        log.error("PyVSI is currently a read-only interface.")
        return NULL

    if pUserData is NULL:
        log.error("PyVSI filesystem accessed with uninitialized filesystem info.")
        return NULL
    cdef dict filesystem_info = <object>pUserData

    try:
        file_wrapper = filesystem_info[pszFilename]
    except KeyError:
        log.error("File-like object not found in virtual filesystem: %s", pszFilename)
        return NULL

    if not hasattr(file_wrapper, "_file_obj"):
        log.error("Unexpected file object found in PyVSI filesystem.")
        return NULL
    return <void *>file_wrapper

## File functions


cdef vsi_l_offset pyvsi_tell(void *pFile) with gil:
    cdef object file_wrapper = <object>pFile
    cdef object file_obj = file_wrapper._file_obj
    cdef int pos = file_obj.tell()
    return <vsi_l_offset>pos


cdef int pyvsi_seek(void *pFile, vsi_l_offset nOffset, int nWhence) except -1 with gil:
    cdef object file_wrapper = <object>pFile
    cdef object file_obj = file_wrapper._file_obj
    # TODO: Add "seekable" check?
    file_obj.seek(nOffset, nWhence)
    return 0


cdef size_t pyvsi_read(void *pFile, void *pBuffer, size_t nSize, size_t nCount) with gil:
    cdef object file_wrapper = <object>pFile
    cdef object file_obj = file_wrapper._file_obj
    cdef bytes python_data = file_obj.read(nSize * nCount)
    cdef int num_bytes = len(python_data)
    # NOTE: We have to cast to char* first, otherwise Cython doesn't do the conversion properly
    memcpy(pBuffer, <void*><char*>python_data, num_bytes)
    return <size_t>(num_bytes / nSize)


cdef int pyvsi_read_multi_range(void *pFile, int, void **ppData, const vsi_l_offset *panOffsets, const size_t *panSizes) with gil:
    # Optional
    print("read_multi_range")


cdef VSIRangeStatus pyvsi_get_range_status(void *pFile, vsi_l_offset nOffset, vsi_l_offset nLength) with gil:
    # Optional
    print("get_range_status")


cdef int pyvsi_eof(void *pFile) with gil:
    # Mandatory?
    print("eof")


cdef size_t pyvsi_write(void *pFile, const void *pBuffer, size_t nSize, size_t nCount) with gil:
    print("write")


cdef int pyvsi_flush(void *pFile) with gil:
    # Optional
    print("flush")


cdef int pyvsi_truncate(void *pFile, vsi_l_offset nNewSize) with gil:
    print("truncate")


cdef int pyvsi_close(void *pFile) except -1 with gil:
    # Optional
    print("close")
    cdef object file_wrapper = <object>pFile
    del _FILESYSTEM_INFO[file_wrapper._pyvsi_path]
    return 0


cdef int install_rasterio_pyvsi_plugin(VSIFilesystemPluginCallbacksStruct *callbacks_struct):
    """Install handlers for python file-like objects if it isn't already installed."""
    cdef int install_status
    if VSIFileManager.GetHandler("") == VSIFileManager.GetHandler(FILESYSTEM_PREFIX_BYTES):
        log.debug("Installing PyVSI filesystem handler plugin...")
        install_status = VSIInstallPluginHandler(FILESYSTEM_PREFIX_BYTES, callbacks_struct)
        return install_status
    return 0


cdef class PyVSIFileBase:

    cdef VSIFilesystemPluginCallbacksStruct* _vsif

    def __cinit__(self, file_or_bytes, *args, **kwargs):
        self._vsif = VSIAllocFilesystemPluginCallbacksStruct()
        # pUserData will be set later
        self._vsif.open = <VSIFilesystemPluginOpenCallback>pyvsi_open

        self._vsif.tell = <VSIFilesystemPluginTellCallback>pyvsi_tell
        self._vsif.seek = <VSIFilesystemPluginSeekCallback>pyvsi_seek
        self._vsif.read = <VSIFilesystemPluginReadCallback>pyvsi_read
        # self._vsif.eof = <VSIFilesystemPluginEofCallback>pyvsi_eof
        self._vsif.close = <VSIFilesystemPluginCloseCallback>pyvsi_close

    def __dealloc__(self):
        if self._vsif is not NULL:
            self._vsif.pUserData = NULL
            VSIFreeFilesystemPluginCallbacksStruct(self._vsif)
            self._vsif = NULL

    def __init__(self, file_or_bytes=None, dirname=None, filename=None, ext='.tif'):
        """A file in an in-memory filesystem.

        Parameters
        ----------
        file_or_bytes : file or bytes
            A file opened in binary mode or bytes
        filename : str
            A filename for the in-memory file under /vsimem
        ext : str
            A file extension for the in-memory file under /vsimem. Ignored if
            filename was provided.

        """
        if isinstance(file_or_bytes, (bytes, str)) or not hasattr(file_or_bytes, "read"):
            raise TypeError("PyVSIFile expects file-like objects only.")

        # Make an in-memory directory specific to this dataset to help organize
        # auxiliary files.
        # XXX: Do we really need directories?
        self._dirname = dirname or str(uuid4())

        if filename:
            # GDAL's SRTMHGT driver requires the filename to be "correct" (match
            # the bounds being written)
            self.name = "{0}{1}/{2}".format(FILESYSTEM_PREFIX, self._dirname, filename)
        else:
            # GDAL 2.1 requires a .zip extension for zipped files.
            self.name = "{0}{1}/{1}.{2}".format(FILESYSTEM_PREFIX, self._dirname, ext.lstrip('.'))

        self._path = self.name.encode('utf-8')
        self._pyvsi_path = self._path[len(FILESYSTEM_PREFIX):]
        self._file_obj = file_or_bytes
        self.mode = "r"
        self.closed = False

        # TODO: Error checking
        _FILESYSTEM_INFO[self._pyvsi_path] = self
        self._vsif.pUserData = <void*>_FILESYSTEM_INFO
        install_rasterio_pyvsi_plugin(self._vsif)

    def exists(self):
        """Test if the in-memory file exists.

        Returns
        -------
        bool
            True if the in-memory file exists.

        """
        print("exists")
        cdef VSIStatBufL st_buf
        return VSIStatL(self._path, &st_buf) == 0

    def __len__(self):
        """Length of the file's buffer in number of bytes.

        Returns
        -------
        int
        """
        print("__len__")
        try:
            return self._file_obj.size
        except AttributeError:
            # FIXME: What should this actually do?
            return 0

    def close(self):
        print("Python close")
        # FIXME: _vsif is now the actual filesystem, this should deal with the file
        # if hasattr(self, '_vsif') and self._vsif is not NULL:
        #     print("vsif is not Null")
        #     VSIFCloseL(<VSILFILE *>self._vsif)
        # self._vsif = NULL
        # _delete_dataset_if_exists(self.name)
        # VSIRmdir(self._dirname.encode("utf-8"))
        self.closed = True

    def seek(self, offset, whence=0):
        print("python seek")
        return self._file_obj.seek(offset, whence)

    def tell(self):
        print("python tell")
        return self._file_obj.tell()
