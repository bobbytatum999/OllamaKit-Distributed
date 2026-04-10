import sys

pbxproj_path = 'OllamaKit.xcodeproj/project.pbxproj'
with open(pbxproj_path, 'r') as f:
    content = f.read()

# Generate UUIDs
file_ref_id = '0F0000000000000000000001'
build_file_id = '0F0000000000000000000002'

added_ref = f'\t\t{file_ref_id} /* ThermalMonitorService.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ThermalMonitorService.swift; sourceTree = "<group>"; }};\n'
added_build = f'\t\t{build_file_id} /* ThermalMonitorService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* ThermalMonitorService.swift */; }};\n'

if 'ThermalMonitorService.swift' in content:
    print("Already added")
    sys.exit(0)

# 1. PBXBuildFile
content = content.replace(
    '/* Begin PBXBuildFile section */\n',
    f'/* Begin PBXBuildFile section */\n{added_build}'
)

# 2. PBXFileReference
content = content.replace(
    '/* Begin PBXFileReference section */\n',
    f'/* Begin PBXFileReference section */\n{added_ref}'
)

# 3. Add to Services group
content = content.replace(
    '000000010000000000000108 /* ServerManager.swift */,',
    f'000000010000000000000108 /* ServerManager.swift */,\n\t\t\t\t{file_ref_id} /* ThermalMonitorService.swift */,'
)

# 4. Add to SourcesBuildPhase
content = content.replace(
    '000000010000000000000008 /* ServerManager.swift in Sources */,',
    f'000000010000000000000008 /* ServerManager.swift in Sources */,\n\t\t\t\t{build_file_id} /* ThermalMonitorService.swift in Sources */,'
)

with open(pbxproj_path, 'w') as f:
    f.write(content)

print('Updated pbxproj')
