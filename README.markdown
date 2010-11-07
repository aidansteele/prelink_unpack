prelink_unpack
========

`prelink_unpack` is a command-line tool for unpacking the prelinked kernel used by [iOS](http://www.apple.com/iphone/ios4/). It is written in Objective-C and uses the Foundation framework. 

It returns both the unpacked `mach_kernel` Mach-O object and the unpacked kernel extensions. Example usage:

    $ ./prelink_unpack kernelcache.dump 
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