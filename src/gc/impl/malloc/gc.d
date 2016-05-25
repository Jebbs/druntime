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
module gc.impl.malloc.gc;

import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;

static import core.memory;
private alias BlkAttr = core.memory.GC.BlkAttr;
private alias BlkInfo = core.memory.GC.BlkInfo;

extern (C) void onOutOfMemoryError(void* pretend_sideffect = null) @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */

struct Range
{
    void*  pos;
    size_t len;
    TypeInfo ti; // should be tail const, but doesn't exist for references
}

struct GC
{


	__gshared void** roots  = null;
    __gshared size_t nroots = 0;

    __gshared Range* ranges  = null;
    __gshared size_t nranges = 0;



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
		void** r = cast(void**) realloc( roots,
                                         (nroots+1) * roots[0].sizeof );
        if( r is null )
            onOutOfMemoryError();
        r[nroots++] = p;
        roots = r;
	}

	void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow
	{
		Range* r = cast(Range*) realloc( ranges,
                                         (nranges+1) * ranges[0].sizeof );
        if( r is null )
            onOutOfMemoryError();
        r[nranges].pos = p;
        r[nranges].len = sz;
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
            if( ranges[i].pos is p )
            {
                ranges[i] = ranges[--nranges];
                return;
            }
        }
        assert( false );
	}


}