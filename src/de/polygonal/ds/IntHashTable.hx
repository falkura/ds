/*
Copyright (c) 2008-2016 Michael Baczynski, http://www.polygonal.de

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
package de.polygonal.ds;

#if (flash && alchemy)
import de.polygonal.ds.mem.IntMemory;
#end

import de.polygonal.ds.tools.ArrayTools;
import de.polygonal.ds.tools.Assert.assert;

using de.polygonal.ds.tools.NativeArrayTools;

/**
	An array hash table for mapping integer keys to generic elements
	
	The implementation is based `IntIntHashTable`.
	
**/
#if generic
@:generic
#end
class IntHashTable<T> implements Map<Int, T>
{
	/**
		A unique identifier for this object.
		
		A hash table transforms this key into an index of an array element by using a hash function.
		
		<warn>This value should never be changed by the user.</warn>
	**/
	public var key(default, null):Int = HashKey.next();
	
	/**
		If true, reuses the iterator object instead of allocating a new one when calling ``iterator()``.
		
		The default is false.
		
		<warn>If true, nested iterations are likely to fail as only one iteration is allowed at a time.</warn>
	**/
	public var reuseIterator:Bool = false;
	
	/**
		The size of the allocated storage space for the key/value pairs.
		
		If more space is required to accomodate new elements,``getCapacity()`` is doubled every time ``size`` grows beyond capacity, and split in half when ``size`` is a quarter of capacity.
		
		The capacity never falls below the initial size defined in the constructor.
	**/
	public var capacity(get, never):Int;
	inline function get_capacity():Int
	{
		return mH.capacity;
	}
	
	/**
		The load factor measure the "denseness" of a hash table and is proportional to the time cost to look up an entry.
		
		E.g. assuming that the keys are perfectly distributed, a load factor of 4.0 indicates that each slot stores 4 keys, which have to be sequentially searched in order to find a value.
		
		A high load factor thus indicates poor performance.
		
		If the load factor gets too high, additional slots can be allocated by calling ``rehash()``.
	**/
	public var loadFactor(get, never):Float;
	function get_loadFactor():Float
	{
		return mH.loadFactor;
	}
	
	/**
		The total number of allocated slots.
	**/
	public var slotCount(get, never):Int;
	inline function get_slotCount():Int
	{
		return mH.slotCount;
	}
	
	var mH:IntIntHashTable;
	
	var mVals:Container<T>;
	
	#if alchemy
	var mKeys:IntMemory;
	var mNext:IntMemory;
	#else
	var mNext:Container<Int>;
	var mKeys:Container<Int>;
	#end
	
	var mFree:Int = 0;
	var mKey0:Int = 0;
	var mIndex0:Int = 0;
	
	var mMinCapacity:Int;
	var mShrinkSize:Int;
	var mIterator:IntHashTableIterator<T> = null;
	
	var mTmpArr:Array<Int> = [];
	
	/**
		<assert>`slotCount` is not a power of two</assert>
		<assert>`capacity` is not a power of two</assert>
		<assert>`capacity` is < 2</assert>
		
		@param slotCount the total number of slots into which the hashed keys are distributed.
		This defines the space-time trade off of the hash table.
		Increasing the `slotCount` reduces the computation time (read/write/access) of the hash table at the cost of increased memory use.
		This value is fixed and can only be changed by calling ``rehash()``, which rebuilds the hash table (expensive).
		
		@param capacity the initial physical space for storing the key/value pairs at the time the hash table is created.
		This is also the minimum allowed size of the hash table and cannot be changed in the future. If omitted, the initial `capacity` equals `slotCount`.
		The `capacity` is automatically adjusted according to the storage requirements based on two rules:
		<ul>
		<li>If the hash table runs out of space, the `capacity` is doubled.</li>
		<li>If the size falls below a quarter of the current `capacity`, the `capacity` is cut in half while the minimum `capacity` can't fall below `capacity`.</li>
		</ul>
	**/
	public function new(slotCount:Int, capacity = -1)
	{
		if (slotCount == M.INT16_MIN) return;
		assert(slotCount > 0);
		
		if (capacity == -1) capacity = slotCount;
		
		mMinCapacity = capacity;
		
		mH = new IntIntHashTable(slotCount, capacity);
		mVals = NativeArrayTools.init(capacity);
		
		#if alchemy
		mNext = new IntMemory(capacity, "IntHashTable.mNext");
		mKeys = new IntMemory(capacity, "IntHashTable.mKeys");
		mKeys.fill(IntIntHashTable.KEY_ABSENT);
		#else
		mNext = NativeArrayTools.init(capacity);
		mKeys = NativeArrayTools.init(capacity);
		for (i in 0...capacity) mKeys[i] = IntIntHashTable.KEY_ABSENT;
		#end
		
		for (i in 0...capacity - 1) setNext(i, i + 1);
		setNext(capacity - 1, IntIntHashTable.NULL_POINTER);
	}
	
	/**
		Counts the total number of collisions.
		
		A collision occurs when two distinct keys are hashed into the same slot.
	**/
	public function getCollisionCount():Int
	{
		return mH.getCollisionCount();
	}
	
	/**
		Returns the value that is mapped to `key` or null if `key` does not exist.
		
		Uses move-to-front-on-access which reduces access time when similar keys are frequently queried.
	**/
	public inline function getFront(key:Int):T
	{
		if (mKey0 == key)
			return mVals[mIndex0];
		else
		{
			var i = mH.getFront(key);
			if (i == IntIntHashTable.KEY_ABSENT)
				return null;
			else
			{
				mKey0 = key;
				return mVals[mIndex0 = i];
			}
		}
	}
	
	/**
		Maps `val` to `key` in this map, but only if `key` does not exist yet.
		<assert>out of space - hash table is full but not resizable</assert>
		@return true if `key` was mapped to `val` for the first time.
	**/
	public inline function setIfAbsent(key:Int, val:T):Bool
	{
		assert(key != IntIntHashTable.KEY_ABSENT, "key 0x80000000 is reserved");
		
		if ((size == capacity))
		{
			if (mH.setIfAbsent(key, mFree))
			{
				invalidate();
				
				grow(capacity >> 1);
				
				mVals[mFree] = val;
				setKey(mFree, key);
				mFree = getNext(mFree);
				return true;
			}
			else
				return false;
		}
		else
		{
			if (mH.setIfAbsent(key, mFree))
			{
				invalidate();
				
				mVals[mFree] = val;
				setKey(mFree, key);
				mFree = getNext(mFree);
				return true;
			}
			else
				return false;
		}
	}
	
	/**
		Redistributes all keys over `slotCount`.
		
		This is an expensive operations as the hash table is rebuild from scratch.
		<assert>`slotCount` is not a power of two</assert>
	**/
	public function rehash(slotCount:Int)
	{
		mH.rehash(slotCount);
	}
	
	/**
		Remaps the first occurrence of `key` to a new value `val`.
		@return true if `val` was successfully remapped to `key`.
	**/
	public inline function remap(key:Int, val:T):Bool
	{
		var i = mH.get(key);
		if (i != IntIntHashTable.KEY_ABSENT)
		{
			mVals[i] = val;
			return true;
		}
		else
			return false;
	}
	
	/**
		Creates and returns an unordered array of all keys.
	**/
	public function toKeyArray():Array<Int>
	{
		return mH.toKeyArray();
	}
	
	/**
		Returns a string representing the current object.
		
		Example:
		<pre class="prettyprint">
		class Foo extends de.polygonal.ds.HashableItem {
		    var val:Int;
		    public function new(val:Int) {
		        super();
		        this.val = val;
		    }
		    public function toString():String {
		        return "{ Foo " + val + " }";
		    }
		}
		
		class Main
		{
		    static function main() {
		        var hash = new de.polygonal.ds.IntHashTable<Foo>(16);
		        for (i in 0...4) hash.set(i, new Foo(i));
		        trace(hash);
		    }
		}</pre>
		<pre class="console">
		{ IntHashTable size/capacity: 4/16, load factor: 0.25 }
		[
		   0 -> { Foo 0 }
		   1 -> { Foo 1 }
		   2 -> { Foo 2 }
		   3 -> { Foo 3 }
		]</pre>
	**/
	public function toString():String
	{
		var s = Printf.format("{ IntHashTable size/capacity: %d/%d, load factor: %.2f }", [size, capacity, loadFactor]);
		if (isEmpty()) return s;
		s += "\n[\n";
		
		var max = 0.;
		for (key in keys()) max = Math.max(max, key);
		var i = 1;
		while (max != 0)
		{
			i++;
			max = Std.int(max / 10);
		}
		
		for (key in keys())
			s += Printf.format("  %- " + i + "d -> %s\n", [key, Std.string(mVals[mH.getFront(key)])]);
		s += "]";
		return s;
	}
	
	/* INTERFACE Map */
	
	/**
		Returns true if this map contains a mapping for the value `val`.
	**/
	public inline function has(val:T):Bool
	{
		var exists = false;
		for (i in 0...capacity)
		{
			if (_hasKey(i))
			{
				if (mVals[i] == val)
				{
					exists = true;
					break;
				}
			}
		}
		return exists;
	}
	
	/**
		Returns true if this map contains `key`.
	**/
	public inline function hasKey(key:Int):Bool
	{
		return mH.hasKey(key);
	}
	
	/**
		Counts the number of mappings for `key`.
	**/
	public function count(key:Int):Int
	{
		return mH.count(key);
	}
	
	/**
		Returns the first value that is mapped to `key` or null if `key` does not exist.
	**/
	public inline function get(key:Int):T
	{
		var i = mH.get(key);
		if (i == IntIntHashTable.KEY_ABSENT)
			return null;
		else
			return mVals[i];
	}
	
	/**
		Stores all values that are mapped to `key` in `out` or returns 0 if `key` does not exist.
		@return the total number of values mapped to `key`.
	**/
	public function getAll(key:Int, out:Array<T>):Int
	{
		var i = mH.get(key);
		if (i == IntIntHashTable.KEY_ABSENT)
			return 0;
		else
		{
			var c = mH.getAll(key, mTmpArr);
			for (i in 0...c) out[i] = mVals[mTmpArr[i]];
			return c;
		}
	}
	
	/**
		Maps the value `val` to `key`.
		
		The method allows duplicate keys.
		
		<warn>To ensure unique keys either use ``hasKey()`` before ``set()`` or ``setIfAbsent()``</warn>
		<assert>out of space - hash table is full but not resizable</assert>
		<assert>key 0x80000000 is reserved</assert>
		@return true if `key` was added for the first time, false if another instance of `key` was inserted.
	**/
	public function set(key:Int, val:T):Bool
	{
		assert(key != IntIntHashTable.KEY_ABSENT, "key 0x80000000 is reserved");
		
		invalidate();
		if (size == capacity)
		{
			grow(capacity);
		}
		mH.set(key, mFree);
		mVals[mFree] = val;
		setKey(mFree, key);
		
		mFree = getNext(mFree);
		return true;
	}
	
	/**
		Removes the first occurrence of `key`.
		@return true if `key` is successfully removed.
	**/
	public function delete(key:Int):Bool
	{
		var i = mH.get(key);
		if (i == IntIntHashTable.KEY_ABSENT)
			return false;
		else
		{
			invalidate();
			
			mVals[i] = null;
			clrKey(i);
			setNext(i, mFree);
			mFree = i;
			
			var doShrink = false;
			
			if (size - 1 == (capacity >> 2) && capacity > mMinCapacity)
				doShrink = true;
			
			mH.delete(key);
			
			if (doShrink) shrink();
			return true;
		}
	}
	
	/**
		Creates a `ListSet` object of the values in this map.
	**/
	public function toValSet():Set<T>
	{
		var s = new ListSet<T>();
		for (i in 0...capacity)
		{
			if (_hasKey(i))
				s.set(mVals[i]);
		}
		return s;
	}
	
	/**
		Creates a `ListSet` object of the keys in this map.
	**/
	public function toKeySet():Set<Int>
	{
		return mH.toKeySet();
	}
	
	/**
		Returns a new `IntIntHashTableKeyIterator` object to iterate over all keys stored in this map.
		
		The keys are visited in a random order.
		
		See <a href="http://haxe.org/ref/iterators" target="mBlank">http://haxe.org/ref/iterators</a>
	**/
	public function keys():Itr<Int>
	{
		return mH.keys();
	}
	
	/* INTERFACE Collection */
	
	/**
		The total number of key/value pairs.
	**/
	public var size(get, never):Int;
	inline function get_size():Int
	{
		return mH.size;
	}
	
	/**
		Destroys this object by explicitly nullifying all key/values.
		
		<warn>If "alchemy memory" is used, always call this method when the life cycle of this object ends to prevent a memory leak.</warn>
	**/
	public function free()
	{
		mVals.nullify();
		mVals = null;
		
		#if (flash && alchemy)
		mNext.free();
		mKeys.free();
		#end
		
		mKeys = null;
		mNext = null;
		
		mH.free();
		mH = null;
		if (mIterator != null)
		{
			mIterator.free();
			mIterator = null;
		}
		mTmpArr = null;
	}
	
	/**
		Same as ``has()``.
	**/
	public function contains(val:T):Bool
	{
		return has(val);
	}

	/**
		Removes all occurrences of the value `val`.
		@return true if `val` was removed, false if `val` does not exist.
	**/
	public function remove(x:T):Bool
	{
		var t = mTmpArr;
		var c = 0;
		for (i in 0...capacity)
			if (_hasKey(i))
				if (mVals[i] == x)
					t[c++] = getKey(i);
		
		for (i in 0...c) delete(t[i]);
		return c > 0;
	}
	
	/**
		Removes all key/value pairs.
		@param gc if true, nullifies references of all values and shrinks the hash table to the initial capacity defined in the constructor.
	**/
	public function clear(gc:Bool = false)
	{
		mH.clear(gc);
		for (i in 0...capacity) clrKey(i);
		
		if (gc)
		{
			while (capacity > mMinCapacity) shrink();
			
			for (i in 0...capacity)
			{
				mVals[i] = null;
				clrKey(i);
			}
		}
		
		for (i in 0...capacity - 1) setNext(i, i + 1);
		setNext(capacity - 1, IntIntHashTable.NULL_POINTER);
		mFree = 0;
	}

	/**
		Returns a new `IntHashTableIterator` object to iterate over all values contained in this hash table.
		
		The values are visited in a random order.
		
		See <a href="http://haxe.org/ref/iterators" target="mBlank">http://haxe.org/ref/iterators</a>
	**/
	public function iterator():Itr<T>
	{
		if (reuseIterator)
		{
			if (mIterator == null)
				mIterator = new IntHashTableIterator<T>(this);
			else
				mIterator.reset();
			return mIterator;
		}
		else
			return new IntHashTableIterator<T>(this);
	}
	
	/**
		Returns true if this hash table is empty.
	**/
	public inline function isEmpty():Bool
	{
		return mH.isEmpty();
	}
	
	/**
		Returns an unordered array containing all values in this hash table.
	**/
	public function toArray():Array<T>
	{
		if (size == 0) return [];
		
		var out = ArrayTools.alloc(size);
		var j = 0, vals = mVals;
		for (i in 0...capacity)
			if (_hasKey(i))
				out[j++] = vals.get(i);
		return out;
	}
	
	/**
		Duplicates this hash table. Supports shallow (structure only) and deep copies (structure & elements).
		<assert>element is not of type `Cloneable`</assert>
		@param assign if true, the `copier` parameter is ignored and primitive elements are copied by value whereas objects are copied by reference.
		If false, the ``clone()`` method is called on each element. <warn>In this case all elements have to implement `Cloneable`.</warn>
		@param copier a custom function for copying elements. Replaces ``element::clone()`` if `assign` is false.
	**/
	public function clone(assign:Bool = true, copier:T->T = null):Collection<T>
	{
		var c = new IntHashTable<T>(M.INT16_MIN);
		c.key = HashKey.next();
		c.mH = cast mH.clone(false);
		
		var capacity = capacity;
		
		if (assign)
		{
			c.mVals = NativeArrayTools.init(capacity);
			for (i in 0...capacity) c.mVals[i] = mVals[i];
		}
		else
		{
			var t = NativeArrayTools.init(capacity);
			if (copier != null)
			{
				for (i in 0...capacity)
				{
					if (_hasKey(i))
						t[i] = copier(mVals[i]);
				}
			}
			else
			{
				var c:Cloneable<T> = null;
				for (i in 0...capacity)
				{
					if (_hasKey(i))
					{
						assert(Std.is(mVals[i], Cloneable), 'element is not of type Cloneable (${mVals[i]})');
						
						c = cast mVals[i];
						t[i] = c.clone();
					}
				}
			}
			c.mVals = t;
		}
		
		c.mFree = mFree;
		c.mKey0 = mKey0;
		c.mIndex0 = mIndex0;
		
		#if alchemy
		c.mKeys = mKeys.clone();
		c.mNext = mNext.clone();
		#else
		c.mKeys = NativeArrayTools.copy(mKeys);
		c.mNext = NativeArrayTools.copy(mNext);
		//c.mKeys = NativeArrayTools.init(mKeys.length);
		//c.mNext = NativeArrayTools.init(mNext.length);
		//for (i in 0...Std.int(mKeys.length)) c.mKeys[i] = mKeys[i];
		//for (i in 0...Std.int(mNext.length)) c.mNext[i] = mNext[i];
		#end
		return c;
	}
	
	inline function grow(oldSize:Int)
	{
		var newSize = oldSize << 1;
		
		#if alchemy
		mNext.resize(newSize);
		mKeys.resize(newSize);
		#else
		var t = NativeArrayTools.init(newSize);
		for (i in 0...oldSize) t[i] = mNext[i];
		mNext = t;
		var t = NativeArrayTools.init(newSize);
		for (i in 0...oldSize) t[i] = mKeys[i];
		mKeys = t;
		#end
		
		for (i in oldSize...newSize) clrKey(i);
		for (i in oldSize - 1...newSize - 1) setNext(i, i + 1);
		setNext(newSize - 1, IntIntHashTable.NULL_POINTER);
		mFree = oldSize;
		
		var t = NativeArrayTools.init(newSize);
		for (i in 0...oldSize) t[i] = mVals[i];
		mVals = t;
	}
	
	inline function shrink()
	{
		var oldSize = capacity << 1;
		var newSize = capacity;
		
		#if alchemy
		mNext.resize(newSize);
		#else
		mNext = NativeArrayTools.init(newSize);
		#end
		
		for (i in 0...newSize - 1) setNext(i, i + 1);
		setNext(newSize - 1, IntIntHashTable.NULL_POINTER);
		mFree = 0;
		
		var tmpKeys = NativeArrayTools.init(newSize);
		for (i in 0...newSize) tmpKeys[i] = IntIntHashTable.KEY_ABSENT;
		
		var tmpVals = NativeArrayTools.init(newSize);
		
		for (i in mH)
		{
			tmpKeys[mFree] = getKey(i);
			tmpVals[mFree] = mVals[i];
			mFree = getNext(mFree);
		}
		
		#if (flash && alchemy)
		mKeys = IntMemory.ofVector(tmpKeys);
		#else
		mKeys = tmpKeys;
		#end
		
		mVals = tmpVals;
		
		for (i in 0...mFree) mH.remap(getKey(i), i);
	}
	
	inline function invalidate()
	{
		mKey0 = IntIntHashTable.KEY_ABSENT;
	}
	
	inline function getNext(i:Int) return mNext.get(i);
	inline function setNext(i:Int, x:Int) mNext.set(i, x);
	
	inline function getKey(i:Int) return mKeys.get(i);
	inline function setKey(i:Int, x:Int) mKeys.set(i, x);
	
	inline function clrKey(i:Int) mKeys.set(i, IntIntHashTable.KEY_ABSENT);
	
	inline function _hasKey(i:Int) return mKeys.get(i) != IntIntHashTable.KEY_ABSENT;
}

#if generic
@:generic
#end
@:access(de.polygonal.ds.IntHashTable)
@:dox(hide)
class IntHashTableIterator<T> implements de.polygonal.ds.Itr<T>
{
	var mObject:IntHashTable<T>;
	var mVals:Container<T>;
	
	#if alchemy
	var mKeys:IntMemory;
	#else
	var mKeys:Container<Int>;
	#end
	
	var mI:Int;
	var mS:Int;
	
	public function new(x:IntHashTable<T>)
	{
		mObject = x;
		reset();
	}
	
	public function free()
	{
		mObject = null;
		mVals = null;
		mKeys = null;
	}
	
	public function reset():Itr<T>
	{
		mVals = mObject.mVals;
		mKeys = mObject.mKeys;
		mS = mObject.mH.capacity;
		mI = 0;
		
		#if (flash && alchemy)
		while (mI < mS && mKeys.get(mI) == IntIntHashTable.KEY_ABSENT) mI++;
		#else
		while (mI < mS && mKeys[mI] == IntIntHashTable.KEY_ABSENT) mI++;
		#end
		return this;
	}
	
	public inline function hasNext():Bool
	{
		return mI < mS;
	}
	
	public inline function next():T
	{
		#if (flash && alchemy)
		var v = mVals.get(mI);
		while (++mI < mS && mKeys.get(mI) == IntIntHashTable.KEY_ABSENT) {}
		#else
		var v = mVals[mI];
		while (++mI < mS && mKeys[mI] == IntIntHashTable.KEY_ABSENT) {}
		#end
		return v;
	}
	
	public function remove()
	{
		throw "unsupported operation";
	}
}