prelink_unpack
========

`prelink_unpack` is a command-line tool for unpacking the prelinked kernel used by [iOS](http://www.apple.com/iphone/ios4/). It is written in Objective-C and uses the Foundation framework. 

`prelink_unpack` is complemented by Apple's own `kextcache` for rebuilding unpacked kernels. Refer to the [wiki](https://github.com/aidansteele/prelink_unpack/wiki/Odds-and-Ends) for instructions on how to do this. 

`prelink_unpack` returns both the unpacked `mach_kernel` Mach-O object and the unpacked kernel extensions, symbolicated with entry points and `kmod_info_t` header. Example usage:

    $ ./prelink_unpack kernelcache.dump 
    AppleS5L8900XStart: 0x806ae4c1
    AppleS5L8900XStop: 0x806ae4f5
    AppleHIDKeyboardStart: 0x806c03e9
    AppleHIDKeyboardStop: 0x806c041d
    AppleDiskImagesKernelBackedStart: 0x8035ee2d
    AppleDiskImagesKernelBackedStop: 0x8035ee61
    IOCameraFamilyStart: 0x80555919
    IOCameraFamilyStop: 0x8055594d
    ...
    IOUSBDeviceFamilyStart: 0x802cc425
    IOUSBDeviceFamilyStop: 0x802cc459

    $ ls -R
    kernelcache.dump
    kexts/
    mach_kernel
    prelink_unpack

    ./kexts:
    AppleAMC_r1.kext/
    AppleARM11xxProfile.kext/
    AppleARMIISAudio.kext/
    AppleARMPL080DMAC.kext/
    AppleARMPL192VIC.kext/
    AppleARMPlatform.kext/
    AppleBSDKextStarter.kext/
    ...
    IOStorageFamily.kext/
    IOStreamFamily.kext/
    IOSurface.kext/
    IOTextEncryptionFamily.kext/
    IOUSBDeviceFamily.kext/
    IOUserEthernet.kext/
    L2TP.kext/
    PPP.kext/
    PPTP.kext/
    Sandbox.kext/

`prelink_unpack` is [MIT](http://www.opensource.org/licenses/mit-license.html)-licensed. `RegexKitLite` is [BSD](http://www.opensource.org/licenses/bsd-license.php)-licensed. 