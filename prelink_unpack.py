import struct
import plistlib
import idc
import idaapi

struct__mach_header = "=4sIIIIII"
struct__load_command = "=II"
struct__segment_command = "=II16sIIIIIIII"
struct__section = "=16s16sIIIIIIIII"
struct__kmod_info = "=IiI64s64siIIIIII"
struct__uint32_t = "=I"

LC_SEGMENT = 0x1
MH_M_MAGIC = 0
MH_M_NCMDS = 4
MH_MAGIC = 'feedface'.decode('hex')
MH_CIGAM = 'cefaedfe'.decode('hex')

LC_M_CMD = 0
LC_M_CMDSIZE = 1

SC_M_SEGNAME = 2
SC_M_VMADDR = 3
SC_M_FILEOFF = 5
SC_M_FILESIZE = 6
SC_M_NSECTS = 9

SECT_M_SECTNAME = 0
SECT_M_ADDR = 2
SECT_M_SIZE = 3
SECT_M_OFFSET = 4

KM_M_START = 10
KM_M_STOP = 11

PL_KEY_INFODICT = '_PrelinkInfoDictionary'
PL_KEY_LOADADDR = '_PrelinkExecutableLoadAddr'
PL_KEY_BINNAME = 'CFBundleExecutable'
PL_KEY_KMODINFO = '_PrelinkKmodInfo'

f = open("kernel.out", "rb")
k = f.read()

def nullstrip(s):
	try:
		s = s[:s.index('\x00')]
	except ValueError:
		pass
	return s

def segmentWithName(k, name):
	header = struct.unpack_from(struct__mach_header, k)

	loadCommandOffset = struct.calcsize(struct__mach_header)
	for idx in range(header[MH_M_NCMDS]): # mach_header.ncmds
		loadCommand = struct.unpack_from(struct__load_command, k[loadCommandOffset:])

		if loadCommand[LC_M_CMD] == LC_SEGMENT:
			segmentCommand = struct.unpack_from(struct__segment_command, k[loadCommandOffset:])
			segmentName = nullstrip(segmentCommand[SC_M_SEGNAME])
			
			if cmp(segmentName, name) == 0:
				return (segmentCommand, loadCommandOffset)
				
		loadCommandOffset = loadCommandOffset + loadCommand[LC_M_CMDSIZE]

def sectionWithQualifiedName(k, names):
    #segment, segmentOffset = segmentWithName(k, names[0])
    header = struct.unpack_from(struct__mach_header, k)

    loadCommandOffset = struct.calcsize(struct__mach_header)
    for idx in range(header[MH_M_NCMDS]): # mach_header.ncmds
            loadCommand = struct.unpack_from(struct__load_command, k[loadCommandOffset:])

            if loadCommand[LC_M_CMD] == LC_SEGMENT:
                    segmentCommand = struct.unpack_from(struct__segment_command, k[loadCommandOffset:])
                    
                    for idx in range(segmentCommand[SC_M_NSECTS]):
                        sectionOffset = loadCommandOffset + struct.calcsize(struct__segment_command) + (idx * struct.calcsize(struct__section))
                        section = struct.unpack_from(struct__section, k[sectionOffset:])

                        sectionName = nullstrip(section[SECT_M_SECTNAME])
                        segmentName = nullstrip(segmentCommand[SC_M_SEGNAME])

                        if cmp(sectionName, names[1]) == 0: #and cmp(segmentName, names[0]) == 0:
                            return (section, sectionOffset)

def prelinkInfo(k):
	segment, _ = segmentWithName(k, "__PRELINK_INFO")
	start = segment[5]
	end = segment[5] + segment[6]
	plist = nullstrip(k[start:end])
	
	dictionaries = plistlib.readPlistFromString(plist)
	return dictionaries[PL_KEY_INFODICT]
	
def kextObjects(k):
	segment, _ = segmentWithName(k, "__PRELINK_TEXT")
	start = segment[5]
	end = segment[5] + segment[6]
	
	objects = []
	idx = start
	while idx < end:
		obj_start = idx + k[idx:].find(MH_MAGIC) + 1
		obj_size = sizeOfObject(k[obj_start:])
		obj_end = obj_start + obj_size
		
		obj = k[obj_start:obj_end]
		objects.append((obj, obj_start, obj_size))
		
		idx = obj_end
		
	return objects
		
def sizeOfObject(k):
	header = struct.unpack_from(struct__mach_header, k)
	size = 0
	offset = 0
	
	if cmp(header[MH_M_MAGIC], MH_MAGIC) != 0 and cmp(header[MH_M_MAGIC], MH_CIGAM) != 0:
		return
	
	loadCommandOffset = struct.calcsize(struct__mach_header)
	for idx in range(header[MH_M_NCMDS]): # mach_header.ncmds
		loadCommand = struct.unpack_from(struct__load_command, k[loadCommandOffset:])
		
		if loadCommand[LC_M_CMD] == LC_SEGMENT:
			segmentCommand = struct.unpack_from(struct__segment_command, k[loadCommandOffset:])
			
			if segmentCommand[SC_M_FILEOFF] > offset:
				offset = segmentCommand[SC_M_FILEOFF]
				size = segmentCommand[SC_M_FILESIZE]

	return offset + size
	
def nameKextObjects(objs, infoDict):
	named_objs = {}
	
	for obj, obj_off, obj_size in objs:
		header = struct.unpack_from(struct__mach_header, obj)
		loadCommandOffset = struct.calcsize(struct__mach_header)

		for idx in range(header[MH_M_NCMDS]): # mach_header.ncmds
			loadCommand = struct.unpack_from(struct__load_command, obj[loadCommandOffset:])

			if loadCommand[LC_M_CMD] == LC_SEGMENT:
				segmentCommand = struct.unpack_from(struct__segment_command, obj[loadCommandOffset:])
				vmAddr = segmentCommand[SC_M_VMADDR]
				
				for kextDescriptor in infoDict:
					pl_vmAddr = kextDescriptor.get(PL_KEY_LOADADDR)
					pl_kextName = kextDescriptor.get(PL_KEY_BINNAME)
					
					if pl_vmAddr == vmAddr - 0x1000:
						named_objs[pl_kextName] = (obj, obj_off, obj_size)
					
			loadCommandOffset = loadCommandOffset + loadCommand[LC_M_CMDSIZE]
			
	return named_objs
	
def kextEntryPoints(k, infoDict):
	entryPoints = {}

	_, s_off = segmentWithName(k, "__PRELINK_TEXT")
	sectionOffset = s_off + struct.calcsize(struct__segment_command)
	
	textSection = struct.unpack_from(struct__section, k[sectionOffset:])
	sectBase = textSection[SECT_M_OFFSET]
	sectAddr = textSection[SECT_M_ADDR]
	
	for kextDescriptor in infoDict:
		if PL_KEY_KMODINFO in kextDescriptor:
			kmodAddr = kextDescriptor[PL_KEY_KMODINFO]
			kmodOffset = sectBase + (kmodAddr - sectAddr)
			
			kmodInfo = struct.unpack_from(struct__kmod_info, k[kmodOffset:])
			startAddr = kmodInfo[KM_M_START]
			stopAddr = kmodInfo[KM_M_STOP]
			
			entryPoints[kextDescriptor[PL_KEY_BINNAME]] = {'start': startAddr, 'stop': stopAddr}
			
	return entryPoints

def setThumb(addr):
    T_segval = 0
    T_segreg = 20
    
    if addr & 1 == 1:
        addr = addr - 1
        T_segval = 1

    # idc.SetReg cannot be used as idapython will only accept x86 segment registers :(
    # idc.SetReg(addr, "T", T_segval)
    idaapi.splitSRarea1(addr, T_segreg, T_segval, idc.SR_user)

def makeCode(addr):
    setThumb(addr)
    idc.MakeCode(addr)

def makeKmodEntryPoints(addrs, name):
        for entry in ("start", "stop"):
            addr = addrs[entry]
            makeCode(addr)
            idc.MakeFunction(addr, idc.BADADDR) # ida will guess function bounds
            idc.MakeName(addr, "ge::%s::kmod_%s" % (kextName, entry))

def validAddr(addr):
    return ((addr > idc.MinEA()) and (addr < idc.MaxEA()))

def isNamed(addr):
    return idc.hasName(idc.GetFlags(addr))

def isCode(addr):
    return idc.isCode(idc.GetFlags(addr))

def nameVtable(obj, name, obj_offset):
    try:
        section, _ = sectionWithQualifiedName(obj, ("__TEXT", "__const"))
    except TypeError: # not a C++ kmod
        return

    vtableOffset = section[SECT_M_ADDR]
    constSectSize = section[SECT_M_SIZE]

    idc.MakeUnknown(vtableOffset, constSectSize, DOUNK_SIMPLE)
    idc.MakeName(vtableOffset, "_ZTV%d%s" % (len(name), name))
    #idc.OpOff(vtableOffset, -1, 0)

def makeKextCxxMethods(obj, name):
    try:
        section, _ = sectionWithQualifiedName(obj, ("__TEXT", "__const"))
    except TypeError: # not a C++ kmod
        return
    
    vtableOffset = section[SECT_M_OFFSET]
    vtableSize = section[SECT_M_SIZE]

    ptrSize = struct.calcsize(struct__uint32_t)
    nfuncs = vtableSize / ptrSize
    for idx in range(nfuncs):
        addr, = struct.unpack_from(struct__uint32_t, obj[vtableOffset + (idx * ptrSize):])

        if validAddr(addr): #and not isCode(addr):
            makeCode(addr)
            idc.MakeFunction(addr, idc.BADADDR) # ida will guess function bounds

            idc.OpOff(section[SECT_M_ADDR] + (idx * ptrSize), -1, 0)
            
            sanitised = addr & 0xFFFFFFFE
            if not isNamed(sanitised):
                idc.MakeName(sanitised, "_ZN2ge%d%s%dvtable_%dE" % (len(name), name, len(str(idx)) + 7, idx))
                #print name, idx, hex(addr), hex(sanitised), vtableOffset
                #return -1
                

def test():
	plinfo = prelinkInfo(k)
	kep = kextEntryPoints(k, plinfo)

	ko = kextObjects(k)
	nos = nameKextObjects(ko, plinfo)

	for kextName in nos:
            (obj, obj_off, obj_size) = nos[kextName]
            nameVtable(obj, kextName, obj_off)

        for kextName in nos:
            (obj, obj_off, obj_size) = nos[kextName]
            if makeKextCxxMethods(obj, kextName) == -1:
                return


        #for kextName in kep:
        #    makeKmodEntryPoints(kep[kextName], kextName)


	#ko = kextObjects(k)
	#plinfo = prelinkInfo(k)
	#nos = nameKextObjects(ko, plinfo)
	
	#for name in nos:
	#	obj = nos[name]
	#	f2 = open(name, 'wb')
	#	f2.write(obj)
	#	f2.close()
	#return no
