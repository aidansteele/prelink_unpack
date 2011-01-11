prelink_unpack
========

`prelink_unpack.py` is an [IDAPython](http://code.google.com/p/idapython/) tool to assist with unpacking the prelinked kernel used by [iOS](http://www.apple.com/iphone/ios4/). 

`prelink_unpack.py` is complemented by Apple's own `kextcache` for rebuilding unpacked kernels. Refer to the [wiki](https://github.com/aidansteele/prelink_unpack/wiki/Odds-and-Ends) for instructions on how to do this.

`prelink_unpack.py` makes use of the [`plistlib`](http://docs.python.org/library/plistlib.html) library, which is not available by default with IDAPython. It also requires modification to deal with some of the prelinked kernel intricacies, so it is included with `prelink_unpack.py`. 

`prelink_unpack.py` also makes use of the [`struct`](http://docs.python.org/library/struct.html) library for parsing Mach-O objects.

`prelink_unpack.py` is far from a complete, bug-free state. It is _reasonably_ usable and takes a few minutes to run. This is apparently significantly quicker than the [IDC script](http://www.idroidproject.org/wiki/IPhone_Kernel_Drivers_Parser_for_IDA_Pro) currently used by iDroid developers.

`prelink_unpack` is [MIT](http://www.opensource.org/licenses/mit-license.html)-licensed.