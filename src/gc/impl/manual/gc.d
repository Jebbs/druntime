/**
 * This module contains a minimal garbage collector implementation according to
 * published requirements.  This library is mostly intended to serve as an
 * example, but it is usable in applications which do not rely on a garbage
 * collector to clean up memory (ie. when dynamic array resizing is not used,
 * and all memory allocated with 'new' is freed deterministically with
 * 'delete').
 *
 * Please note that block attribute data must be tracked, or at a minimum, the
 * FINALIZE bit must be tracked for any allocated memory block because calling
 * rt_finalize on a non-object block can result in an access violation.  In the
 * allocator below, this tracking is done via a leading uint bitmask.  A real
 * allocator may do better to store this data separately, similar to the basic
 * GC.
 *
 * Copyright: Copyright Sean Kelly 2005 - 2009.
 * License:   $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Sean Kelly
 */

/*          Copyright Sean Kelly 2005 - 2009.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module gc.impl.manual.gc;

import gc.config;
import gc.stats;
import gc.proxy;
import gc.gc;

import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;

static import core.memory;

private
{
    alias BlkAttr = core.memory.GC.BlkAttr;
    alias BlkInfo = core.memory.GC.BlkInfo;
    alias RootIterator = int delegate(scope int delegate(ref Root) nothrow dg);
    alias RangeIterator = int delegate(scope int delegate(ref Range) nothrow dg);
}


extern (C) void onOutOfMemoryError(void* pretend_sideffect = null) @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */

import core.stdc.stdio : printf;


__gshared GC gcInstance;
__gshared Proxy  pthis;

__gshared gc.gc.GC instance;

void initialize()
{

    import core.stdc.string;

    if(config.gc != "manual")
        return;


    auto p = malloc(__traits(classInstanceSize,ManualGC));

    auto gcInst = cast(ManualGC)memcpy(p, typeid(ManualGC).initializer.ptr, typeid(ManualGC).initializer.length);

    gcInst.__ctor();

    instance = cast(gc.gc.GC)gcInst;

    gc_setGC(instance);

}

class ManualGC: gc.gc.GC
{
    __gshared Root* roots  = null;
    __gshared size_t nroots = 0;

    __gshared Range* ranges  = null;
    __gshared size_t nranges = 0;

    this()
    {

    }

    void Dtor()
    {
        free(roots);
        free(ranges);
    }

    void enable(){}

    void disable(){}

    void collect() nothrow{}

    void minimize() nothrow{}

    uint getAttr(void* p) nothrow
    {
        return 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        return 0;
    }


    uint clrAttr(void* p, uint mask) nothrow
    {
        return 0;
    }

    void *malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        void* p = cstdlib.malloc( size );

        if( size && p is null )
            onOutOfMemoryError();
        return p;
    }

    BlkInfo qalloc( size_t size, uint bits, const TypeInfo ti) nothrow
    {
        BlkInfo retval;
        retval.base = malloc(size, bits, ti);
        retval.size = size;
        retval.attr = bits;
        return retval;
    }

    void *calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        void* p = cstdlib.calloc( 1, size );

        if( size && p is null )
            onOutOfMemoryError();
        return p;
    }

    void *realloc(void *p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        p = cstdlib.realloc( p, size );

        if( size && p is null )
            onOutOfMemoryError();
        return p;
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        return 0;
    }

    size_t reserve(size_t size) nothrow
    {
        return 0;
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    void* addrOf(void *p) nothrow
    {
        return null;
    }


    /**
     * Determine the allocated size of pointer p.  If p is an interior pointer
     * or not a gc allocated pointer, return 0.
     */
    size_t sizeOf(void *p) nothrow
    {
        return 0;
    }


    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    BlkInfo query(void *p) nothrow
    {
        return BlkInfo.init;   
    }


    GCStats stats() nothrow
    {
        return GCStats.init;
    }


    void free(void* p) nothrow
    {
        cstdlib.free(p);
    }

    void addRoot(void* p) nothrow
    {
        Root* r = cast(Root*) cstdlib.realloc( roots, (nroots+1) * roots[0].sizeof );
        if( r is null )
            onOutOfMemoryError();
        r[nroots++] = p;
        roots = r;
    }

    @property int delegate(scope int delegate(ref Root) nothrow dg) rootIter() @nogc
    {
        return &rootsApply;
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        int result = 0;
        for(int i = 0; i < nroots; i++)
        {
            result = dg(roots[i]);

            if(result)
                break;
        }

        return result;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow
    {
        Range* r = cast(Range*) cstdlib.realloc( ranges, (nranges+1) * ranges[0].sizeof );
        if( r is null )
            onOutOfMemoryError();
        r[nranges].pbot = p;
        r[nranges].ptop = p+sz;
        r[nranges].ti = cast()ti;
        ranges = r;
        ++nranges;
    }

    void removeRoot(void* p) nothrow
    {
        for( size_t i = 0; i < nroots; ++i )
        {
            if( roots[i] is p )
            {
                roots[i] = roots[--nroots];
                return;
            }
        }
        assert( false );
    }

    void removeRange(void *p) nothrow
    {
        for( size_t i = 0; i < nranges; ++i )
        {
            if( ranges[i].pbot is p )
            {
                ranges[i] = ranges[--nranges];
                return;
            }
        }
        assert( false );
    }

    @property int delegate(scope int delegate(ref Range) nothrow dg) rangeIter() @nogc
    {
        return &rangesApply;
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        int result = 0;
        for(int i = 0; i < nranges; i++)
        {
            result = dg(ranges[i]);

            if(result)
                break;
        }

        return result;
    }

    void runFinalizers(in void[] segment) nothrow{}


    bool inFinalizer() nothrow
    {
        return false;
    }
}


struct GC
{


    __gshared Root* roots  = null;
    __gshared size_t nroots = 0;

    __gshared Range* ranges  = null;
    __gshared size_t nranges = 0;

    void initialize()
    {
        if(config.gc != "manual")
            return;

        initProxy();

        gc_setProxy(&pthis);
    }

    private void initProxy()
    {
        pthis.gc_enable = function void() { };
        pthis.gc_disable = function void() { };
        pthis.gc_term = function void() { gcInstance.Dtor();};

        pthis.gc_collect = function void() { };
        pthis.gc_minimize = function void() { };

        pthis.gc_getAttr = function uint(void* p) { return 0;};
        pthis.gc_setAttr = function uint(void* p, uint a) { return 0;};
        pthis.gc_clrAttr = function uint(void* p, uint a) { return 0;};

        pthis.gc_malloc = function void*(size_t sz, uint ba, const TypeInfo ti) { return gcInstance.malloc( sz);};
        pthis.gc_qalloc = function BlkInfo(size_t sz, uint ba, const TypeInfo ti) {
            BlkInfo retval;
            retval.base = gcInstance.malloc(sz);
            retval.size = sz;
            retval.attr = ba;
            return retval;};
        pthis.gc_calloc = function void*(size_t sz, uint ba, const TypeInfo ti) { return gcInstance.calloc( sz);};
        pthis.gc_realloc = function void*(void* p, size_t sz, uint ba, const TypeInfo ti) { return gcInstance.realloc( p, sz);};
        pthis.gc_extend = function size_t(void* p, size_t mx, size_t sz, const TypeInfo ti) { return 0;};
        pthis.gc_reserve = function size_t(size_t sz) { return 0;};
        pthis.gc_free = function void(void* p) { gcInstance.free(p);};

        pthis.gc_addrOf = function void*(void* p) { return null;};
        pthis.gc_sizeOf = function size_t(void* p) { return 0;};

        pthis.gc_query = function BlkInfo(void* p) { return BlkInfo.init;};
        pthis.gc_stats = function GCStats() { return GCStats.init;};

        pthis.gc_addRoot = function void(void* p) { gcInstance.addRoot(p);};
        pthis.gc_addRange = function void(void* p, size_t sz, const TypeInfo ti) { gcInstance.addRange( p, sz, ti );};

        pthis.gc_removeRoot = function void(void* p) { gcInstance.removeRoot(p);};
        pthis.gc_removeRange = function void(void*p) { gcInstance.removeRange(p);};
        pthis.gc_runFinalizers = function void(in void[] segment) { };

        pthis.gc_inFinalizer = function bool() { return false;};

        pthis.gc_setProxy = function void(Proxy* p) {
            foreach( r; gcInstance.roots[0 .. gcInstance.nroots] )
                p.gc_addRoot( r );

            foreach( r; gcInstance.ranges[0 .. gcInstance.nranges] )
                p.gc_addRange( r.pbot, r.ptop - r.pbot, r.ti );
        };
        pthis.gc_clrProxy = function void(Proxy* p){
            foreach( r; gcInstance.ranges[0 .. gcInstance.nranges] )
                p.gc_removeRange( r.pbot );

            foreach( r; gcInstance.roots[0 .. gcInstance.nroots] )
                p.gc_removeRoot( r );
        };
    }

    void Dtor()
    {
        free(roots);
        free(ranges);
    }

    void* malloc(size_t sz) nothrow
    {
        void* p = cstdlib.malloc( sz );

        if( sz && p is null )
            onOutOfMemoryError();
        return p;
    }

    void* calloc( size_t sz ) nothrow
    {
        void* p = cstdlib.calloc( 1, sz );

        if( sz && p is null )
            onOutOfMemoryError();
        return p;
    }

    void* realloc( void* p, size_t sz ) nothrow
    {
        p = cstdlib.realloc( p, sz );

        if( sz && p is null )
            onOutOfMemoryError();
        return p;
    }

    void free(void* p) nothrow
    {
        cstdlib.free(p);
    }

    void addRoot(void* p) nothrow
    {
        Root* r = cast(Root*) realloc( roots, (nroots+1) * roots[0].sizeof );
        if( r is null )
            onOutOfMemoryError();
        r[nroots++] = p;
        roots = r;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow
    {
        Range* r = cast(Range*) realloc( ranges, (nranges+1) * ranges[0].sizeof );
        if( r is null )
            onOutOfMemoryError();
        r[nranges].pbot = p;
        r[nranges].ptop = p+sz;
        r[nranges].ti = cast()ti;
        ranges = r;
        ++nranges;
    }

    void removeRoot(void* p) nothrow
    {
        for( size_t i = 0; i < nroots; ++i )
        {
            if( roots[i] is p )
            {
                roots[i] = roots[--nroots];
                return;
            }
        }
        assert( false );
    }

    void removeRange(void *p) nothrow
    {
        for( size_t i = 0; i < nranges; ++i )
        {
            if( ranges[i].pbot is p )
            {
                ranges[i] = ranges[--nranges];
                return;
            }
        }
        assert( false );
    }
}


