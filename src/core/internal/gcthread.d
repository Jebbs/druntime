/**
 * This module creates a thread intended to be used by the GC
 *
 * Copyright: Copyright Jeremy DeHaan 2018.
 * License: Distributed under the
 *      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
 *    (See accompanying file LICENSE)
 * Authors:   Jeremy DeHaan
 * Source:    $(DRUNTIMESRC core/internal/_gcthread.d)
 */
module core.internal.gcthread;

import core.sys.posix.pthread;

alias extern (C) void* function(void*) ThreadFunction;

struct GCThread
{
	pthread_t thread;

    bool create(ThreadFunction fn) nothrow @nogc
    {
        pthread_create(&thread, null, fn, null);
	return true;
    }

    bool join() nothrow @nogc
    {
        pthread_join(thread, null);
	    return true;
    }
}