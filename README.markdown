prelink_unpack
========

`prelink_unpack` is a command-line tool for unpacking the prelinked kernel used by [iOS](http://www.apple.com/iphone/ios4/). It is written in Objective-C and uses the Foundation framework. 

It returns both the unpacked `mach_kernel` Mach-O object and the prelinked kernel extensions. Example usage:

    $ ./prelink_unpack kernelcache.dump 
    $ ls -R
    kernelcache.dump
    kexts
    mach_kernel
    prelink_unpack

    ./kexts:
    com.apple.AppleFSCompression.AppleFSCompressionTypeZlib
    com.apple.IOTextEncryptionFamily
    com.apple.driver.AppleAMC_r1
    com.apple.driver.AppleARM11xxProfile
    com.apple.driver.AppleARMPL080DMAC
    com.apple.driver.AppleARMPL192VIC
    ...
    com.apple.iokit.IOUSBDeviceFamily
    com.apple.iokit.IOUserEthernet
    com.apple.kext.AppleMatch
    com.apple.nke.l2tp
    com.apple.nke.ppp
    com.apple.nke.pptp

`prelink_unpack` is [MIT](http://www.opensource.org/licenses/mit-license.html)-licensed. `RegexKitLite` is [BSD](http://www.opensource.org/licenses/bsd-license.php)-licensed. 