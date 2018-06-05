make -j12 -fposix.mak BUILD=debug
../dmd/generated/dmd gctest/allocationtest.d -defaultlib= -debuglib= -debug -g -L--export-dynamic -Isrc -Lgenerated/linux/debug/64/libdruntime.a -ofgctest/test
