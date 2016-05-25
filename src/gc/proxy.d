/**
 * Contains the external GC interface.
 *
 * Copyright: Copyright Digital Mars 2005 - 2013.
 * License:   $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Walter Bright, Sean Kelly
 */

/*          Copyright Digital Mars 2005 - 2013.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module gc.proxy;

import conservative = gc.impl.conservative.gc;
import malloc = gc.impl.malloc.gc;
import gc.config;
import gc.stats;
import core.stdc.stdlib;

private
{
    __gshared conservative.GC _conservativeGC;
    __gshared malloc.GC _mallocGC;

    static import core.memory;
    alias BlkInfo = core.memory.GC.BlkInfo;

    extern (C) void thread_init();
    extern (C) void thread_term();

    struct Proxy
    {
        extern (C)
        {
            void function() gc_enable;
            void function() gc_disable;
            void function() gc_term;
            
        nothrow:
            void function() gc_collect;
            void function() gc_minimize;

            uint function(void*) gc_getAttr;
            uint function(void*, uint) gc_setAttr;
            uint function(void*, uint) gc_clrAttr;

            void*   function(size_t, uint, const TypeInfo) gc_malloc;
            BlkInfo function(size_t, uint, const TypeInfo) gc_qalloc;
            void*   function(size_t, uint, const TypeInfo) gc_calloc;
            void*   function(void*, size_t, uint ba, const TypeInfo) gc_realloc;
            size_t  function(void*, size_t, size_t, const TypeInfo) gc_extend;
            size_t  function(size_t) gc_reserve;
            void    function(void*) gc_free;

            void*   function(void*) gc_addrOf;
            size_t  function(void*) gc_sizeOf;

            BlkInfo function(void*) gc_query;
            GCStats function() gc_stats;

            void function(void*) gc_addRoot;
            void function(void*, size_t, const TypeInfo ti) gc_addRange;

            void function(void*) gc_removeRoot;
            void function(void*) gc_removeRange;
            void function(in void[]) gc_runFinalizers;

            bool function() gc_inFinalizer;

            void function(Proxy* p) gc_setProxy;
            void function() gc_clrProxy;

        }
    }

    __gshared Proxy  pthis;
    __gshared Proxy* proxy;


    void initConservativeGCProxy()
    {
        pthis.gc_enable = function void() { _conservativeGC.enable();};
        pthis.gc_disable = function void() { _conservativeGC.disable();};
        pthis.gc_term = function void() {
        _conservativeGC.fullCollectNoStack(); // not really a 'collect all' -- still scans
                                  // static data area, roots, and ranges.
        _conservativeGC.Dtor();
        };

        pthis.gc_collect = function void() { _conservativeGC.fullCollect();};
        pthis.gc_minimize = function void() { _conservativeGC.minimize();};

        pthis.gc_getAttr = function uint(void* p) { return _conservativeGC.getAttr(p);};
        pthis.gc_setAttr = function uint(void* p, uint a) { return _conservativeGC.setAttr(p, a);};
        pthis.gc_clrAttr = function uint(void* p, uint a) { return _conservativeGC.clrAttr(p, a);};

        pthis.gc_malloc = function void*(size_t sz, uint ba, const TypeInfo ti) { return _conservativeGC.malloc( sz, ba, null, ti );};
        pthis.gc_qalloc = function BlkInfo(size_t sz, uint ba, const TypeInfo ti) {
            BlkInfo retval;
            retval.base = _conservativeGC.malloc( sz, ba, &retval.size, ti );
            retval.attr = ba;
            return retval;};
        pthis.gc_calloc = function void*(size_t sz, uint ba, const TypeInfo ti) { return _conservativeGC.calloc( sz, ba, null, ti );};
        pthis.gc_realloc = function void*(void* p, size_t sz, uint ba, const TypeInfo ti) { return _conservativeGC.realloc( p, sz, ba, null, ti );};
        pthis.gc_extend = function size_t(void* p, size_t mx, size_t sz, const TypeInfo ti) { return _conservativeGC.extend( p, mx, sz, ti );};
        pthis.gc_reserve = function size_t(size_t sz) { return _conservativeGC.reserve(sz);};
        pthis.gc_free = function void(void* p){ _conservativeGC.free(p);};

        pthis.gc_addrOf = function void*(void* p) { return _conservativeGC.addrOf(p);};
        pthis.gc_sizeOf = function size_t(void* p) { return _conservativeGC.sizeOf(p);};

        pthis.gc_query = function BlkInfo(void* p) { return _conservativeGC.query(p);};
        pthis.gc_stats = function GCStats() {GCStats stats = void; _conservativeGC.getStats( stats ); return stats;};

        pthis.gc_addRoot = function void(void* p) { _conservativeGC.addRoot(p);};
        pthis.gc_addRange = function void(void* p, size_t sz, const TypeInfo ti) { _conservativeGC.addRange( p, sz, ti );};

        pthis.gc_removeRoot = function void(void* p) { _conservativeGC.removeRoot(p);};
        pthis.gc_removeRange = function void(void*p) { _conservativeGC.removeRange(p);};
        pthis.gc_runFinalizers = function void(in void[] segment) { _conservativeGC.runFinalizers(segment);};

        pthis.gc_inFinalizer = function bool() { return _conservativeGC.inFinalizer;};

        pthis.gc_setProxy = function void(Proxy* p) {
            foreach (r; _conservativeGC.rootIter)
                p.gc_addRoot( r );

            foreach (r; _conservativeGC.rangeIter)
                p.gc_addRange( r.pbot, r.ptop - r.pbot, null );
        };
        pthis.gc_clrProxy= function void(){
            foreach (r; _conservativeGC.rootIter)
                proxy.gc_removeRoot( r );

            foreach (r; _conservativeGC.rangeIter)
                proxy.gc_removeRange( r.pbot);
        };
    }

    void initMallocGCProxy()
    {
        pthis.gc_enable = function void() { };
        pthis.gc_disable = function void() { };
        pthis.gc_term = function void() { _mallocGC.Dtor();};

        pthis.gc_collect = function void() { };
        pthis.gc_minimize = function void() { };

        pthis.gc_getAttr = function uint(void* p) { return 0;};
        pthis.gc_setAttr = function uint(void* p, uint a) { return 0;};
        pthis.gc_clrAttr = function uint(void* p, uint a) { return 0;};

        pthis.gc_malloc = function void*(size_t sz, uint ba, const TypeInfo ti) { return _mallocGC.malloc( sz);};
        pthis.gc_qalloc = function BlkInfo(size_t sz, uint ba, const TypeInfo ti) {
            BlkInfo retval;
            retval.base = _mallocGC.malloc(sz);
            retval.size = sz;
            retval.attr = ba;
            return retval;};
        pthis.gc_calloc = function void*(size_t sz, uint ba, const TypeInfo ti) { return _mallocGC.calloc( sz);};
        pthis.gc_realloc = function void*(void* p, size_t sz, uint ba, const TypeInfo ti) { return _mallocGC.realloc( p, sz);};
        pthis.gc_extend = function size_t(void* p, size_t mx, size_t sz, const TypeInfo ti) { return 0;};
        pthis.gc_reserve = function size_t(size_t sz) { return 0;};
        pthis.gc_free = function void(void* p) { _mallocGC.free(p);};

        pthis.gc_addrOf = function void*(void* p) { return null;};
        pthis.gc_sizeOf = function size_t(void* p) { return 0;};

        pthis.gc_query = function BlkInfo(void* p) { return BlkInfo.init;};
        pthis.gc_stats = function GCStats() { return GCStats.init;};

        pthis.gc_addRoot = function void(void* p) { _mallocGC.addRoot(p);};
        pthis.gc_addRange = function void(void* p, size_t sz, const TypeInfo ti) { _mallocGC.addRange( p, sz, ti );};

        pthis.gc_removeRoot = function void(void* p) { _mallocGC.removeRoot(p);};
        pthis.gc_removeRange = function void(void*p) { _mallocGC.removeRange(p);};
        pthis.gc_runFinalizers = function void(in void[] segment) { };

        pthis.gc_inFinalizer = function bool() { return false;};

        pthis.gc_setProxy = function void(Proxy* p) {
            foreach( r; _mallocGC.roots[0 .. _mallocGC.nroots] )
                p.gc_addRoot( r );

            foreach( r; _mallocGC.ranges[0 .. _mallocGC.nranges] )
                p.gc_addRange( r.pos, r.len, r.ti );
        };
        pthis.gc_clrProxy= function void(){
            foreach( r; _mallocGC.ranges[0 .. _mallocGC.nranges] )
                proxy.gc_removeRange( r.pos );

            foreach( r; _mallocGC.roots[0 .. _mallocGC.nroots] )
                proxy.gc_removeRoot( r );
        };
    }

}

extern (C)
{
    void gc_init()
    {

        config.initialize();

        if (config.malloc)
        {
            initMallocGCProxy();
        }
        else
        {
            _conservativeGC.initialize();
            initConservativeGCProxy();
        }

        proxy = &pthis;

        // NOTE: The GC must initialize the thread library
        //       before its first collection.
        thread_init();
    }

    void gc_term()
    {
        // NOTE: There may be daemons threads still running when this routine is
        //       called.  If so, cleaning memory out from under then is a good
        //       way to make them crash horribly.  This probably doesn't matter
        //       much since the app is supposed to be shutting down anyway, but
        //       I'm disabling cleanup for now until I can think about it some
        //       more.
        //
        // NOTE: Due to popular demand, this has been re-enabled.  It still has
        //       the problems mentioned above though, so I guess we'll see.

        pthis.gc_term();

        thread_term();
    }

    void gc_enable()
    {
        proxy.gc_enable();
    }

    void gc_disable()
    {
        proxy.gc_disable();
    }

    void gc_collect() nothrow
    {
        proxy.gc_collect();
    }

    void gc_minimize() nothrow
    {
        proxy.gc_minimize();
    }

    uint gc_getAttr( void* p ) nothrow
    {
        return proxy.gc_getAttr( p );
    }

    uint gc_setAttr( void* p, uint a ) nothrow
    {
        return proxy.gc_setAttr( p, a );
    }

    uint gc_clrAttr( void* p, uint a ) nothrow
    {
        return proxy.gc_clrAttr( p, a );
    }

    void* gc_malloc( size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return proxy.gc_malloc( sz, ba, ti );
    }

    BlkInfo gc_qalloc( size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return proxy.gc_qalloc( sz, ba, ti );
    }

    void* gc_calloc( size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return proxy.gc_calloc( sz, ba, ti );
    }

    void* gc_realloc( void* p, size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return proxy.gc_realloc( p, sz, ba, ti );
    }

    size_t gc_extend( void* p, size_t mx, size_t sz, const TypeInfo ti = null ) nothrow
    {
        return proxy.gc_extend( p, mx, sz,ti );
    }

    size_t gc_reserve( size_t sz ) nothrow
    {
        return proxy.gc_reserve( sz );
    }

    void gc_free( void* p ) nothrow
    {
        return proxy.gc_free( p );
    }

    void* gc_addrOf( void* p ) nothrow
    {
        return proxy.gc_addrOf( p );
    }

    size_t gc_sizeOf( void* p ) nothrow
    {
        return proxy.gc_sizeOf( p );
    }

    BlkInfo gc_query( void* p ) nothrow
    {
        return proxy.gc_query( p );
    }

    // NOTE: This routine is experimental. The stats or function name may change
    //       before it is made officially available.
    GCStats gc_stats() nothrow
    {
        return proxy.gc_stats();
    }

    void gc_addRoot( void* p ) nothrow
    {
        return proxy.gc_addRoot( p );
    }

    void gc_addRange( void* p, size_t sz, const TypeInfo ti = null ) nothrow
    {
        return proxy.gc_addRange( p, sz, ti );
    }

    void gc_removeRoot( void* p ) nothrow
    {
        return proxy.gc_removeRoot( p );
    }

    void gc_removeRange( void* p ) nothrow
    {
        return proxy.gc_removeRange( p );
    }

    void gc_runFinalizers( in void[] segment ) nothrow
    {
        return proxy.gc_runFinalizers( segment );
    }

    bool gc_inFinalizer() nothrow
    {
        return proxy.gc_inFinalizer();
    }

    Proxy* gc_getProxy() nothrow
    {
        return proxy;
    }

    export
    {
        void gc_setProxy( Proxy* p )
        {
            proxy.gc_setProxy(p);

            proxy = p;
        }

        void gc_clrProxy()
        {
            pthis.gc_clrProxy();

            proxy = null;
        }
    }

}
