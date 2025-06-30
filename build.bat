@echo off

rem if arg1 is debug, otherwise release
if "%~1" neq "" if "%~1"=="debug" set DEBUG="1"

:SHADER
if defined DEBUG (
	call dxc -T cs_6_5 -E main -Fo simplecompute.cso -Zi -Od -Qembed_debug simplecompute_cs.hlsl
) else (
	call dxc -T cs_6_5 -E main -Fo simplecompute.cso simplecompute_cs.hlsl
)

:ODIN
if defined DEBUG (
	call odin build . -out:simplecompute.exe -debug -show-timings
) else (
	call odin build . -out:simplecompute.exe -o:speed
)

@echo on