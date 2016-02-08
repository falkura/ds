﻿/*
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

import de.polygonal.ds.tools.ArrayTools;
import de.polygonal.ds.tools.Assert.assert;

using de.polygonal.ds.tools.NativeArrayTools;

/**
	A deque is a "double-ended queue"
	
	This is a linear list for which all insertions and deletions (and usually all accesses) are made at ends of the list.
**/
#if generic
@:generic
#end
class ArrayedDeque<T> implements Deque<T>
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
	
	var mBlockSize:Int;
	var mBlockSizeMinusOne:Int;
	var mBlockSizeShift:Int;
	var mHead:Int = 0;
	var mTail:Int = 1;
	var mTailBlockIndex:Int = 0;
	var mPoolSize:Int = 0;
	var mPoolCapacity:Int;
	
	var mBlocks:Array<Container<T>>;
	var mHeadBlock:Container<T>;
	var mTailBlock:Container<T>;
	var mHeadBlockNext:Container<T> = null;
	var mTailBlockPrev:Container<T> = null;
	var mBlockPool:Array<Container<T>>;
	var mIterator:ArrayedDequeIterator<T> = null;
	
	/**
		<assert>invalid `blockSize`</assert>
		@param blockSize a block represents a contiguous piece of memory; whenever the deque runs out of space an additional block with a capacity of `blockSize` elements is allocated and added to the existing blocks.
		The parameter affects the performance-memory trade-off: a large `blockSize` improves performances but wastes memory if the utilization is low; a small `blockSize` uses memory more efficiently but is slower due to frequent allocation of blocks.
		The default value is 64; the minimum value is 4.
		<warn>`blockSize` has to be a power of two.</warn>
		@param blockPoolSize the total number of blocks to reuse when blocks are removed or relocated (from front to back or vice-versa). This improves performances but uses more memory.
		The default value is 4; a value of 0 disables block pooling.
	**/
	public function new(blockSize:Int = 64, blockPoolCapacity:Int = 4, ?source:Array<T>)
	{
		if (blockSize == M.INT16_MIN) return; //TODO remove
		
		assert(blockSize > 0);
		assert(M.isPow2(blockSize), "blockSize is not a power of 2");
		assert(blockSize >= 4, "blockSize is too small");
		
		mBlockSize = blockSize;
		mBlockSizeMinusOne = blockSize - 1;
		mBlockSizeShift = Bits.ntz(blockSize);
		mPoolCapacity = blockPoolCapacity;
		mBlocks = new Array();
		mBlocks[0] = NativeArrayTools.init(blockSize);
		mHeadBlock = mBlocks[0];
		mTailBlock = mHeadBlock;
		mBlockPool = new Array<Container<T>>();
		
		if (source != null)
			for (i in 0...source.length)
				pushBack(source[i]);
	}
	
	/**
		Returns the first element of this deque.
		<assert>deque is empty</assert>
	**/
	public inline function front():T
	{
		assert(size > 0, "deque is empty");
		
		return (mHead == mBlockSizeMinusOne) ? mHeadBlockNext[0] : mHeadBlock[mHead + 1];
	}
	
	/**
		Inserts the element `x` at the front of this deque.
	**/
	public inline function pushFront(x:T)
	{
		mHeadBlock[mHead--] = x;
		if (mHead == -1) unshiftBlock();
	}
	
	/**
		Removes and returns the element at the beginning of this deque.
		<assert>deque is empty</assert>
	**/
	public inline function popFront():T
	{
		assert(size > 0, "deque is empty");
		
		if (mHead == mBlockSizeMinusOne)
		{
			shiftBlock();
			return mHeadBlock[0];
		}
		else
			return mHeadBlock[++mHead];
	}
	
	/**
		Returns the last element of the deque.
		<assert>deque is empty</assert>
	**/
	public inline function back():T
	{
		assert(size > 0, "deque is empty");
		
		return (mTail == 0) ? (mTailBlockPrev[mBlockSizeMinusOne]) : mTailBlock[mTail - 1];
	}
	
	/**
		Inserts the element `x` at the back of the deque.
	**/
	public inline function pushBack(x:T)
	{
		mTailBlock[mTail++] = x;
		if (mTail == mBlockSize)
			pushBlock();
	}
	
	/**
		Deletes the element at the end of the deque.
		<assert>deque is empty</assert>
	**/
	public function popBack():T
	{
		assert(size > 0, "deque is empty");
		
		if (mTail == 0)
		{
			popBlock();
			return mTailBlock[mBlockSizeMinusOne];
		} 
		else
			return mTailBlock[--mTail];
	}
	
	/**
		Returns the element at index `i` relative to the front of this deque.
		
		The front element is at index [0], the back element is at index [``size`` - 1].
		<assert>deque is empty</assert>
		<assert>`i` out of range</assert>
	**/
	public function getFront(i:Int):T
	{
		assert(i < size, 'index out of range ($i)');
		
		var c = (mHead + 1) + i;
		var b = (c >> mBlockSizeShift);
		return mBlocks[b][c - (b << mBlockSizeShift)];
	}
	
	/**
		Returns the index of the first occurence of the element `x` or -1 if `x` does not exist.
		
		The front element is at index [0], the back element is at index [``size`` - 1].
	**/
	public function indexOfFront(x:T):Int
	{
		for (i in 0...size)
		{
			var c = (mHead + 1) + i;
			var b = (c >> mBlockSizeShift);
			
			if (mBlocks[b][c - (b << mBlockSizeShift)] == x)
				return i;
		}
		return -1;
	}
	
	/**
		Returns the element at index `i` relative to the back of this deque.
		
		The back element is at index [0], the front element is at index [``size`` - 1].
		<assert>deque is empty</assert>
		<assert>`i` out of range</assert>
	**/
	public function getBack(i:Int):T
	{
		assert(i < size, 'index out of range ($i)');
		
		var c = mTail - 1 - i;
		var b = c >> mBlockSizeShift;
		return mBlocks[mTailBlockIndex + b][M.abs(b << mBlockSizeShift) + c];
	}
	
	/**
		Returns the index of the first occurence of the element `x` or -1 if `x` does not exist.
		
		The back element is at index [0], the front element is at index [``size`` - 1].
	**/
	public function indexOfBack(x:T):Int
	{
		for (i in 0...size)
		{
			var c = mTail - 1 - i;
			var b = c >> mBlockSizeShift;
			if (mBlocks[mTailBlockIndex + b][M.abs(b << mBlockSizeShift) + c] == x)
				return i;
		}
		return -1;
	}
	
	
	/**
		Removes all superfluous blocks and overwrites elements stored in empty locations with null.
	**/
	public function pack()
	{
		for (i in 0...mHead + 1) mHeadBlock[i] = cast null;
		for (i in mTail...mBlockSize) mTailBlock[i] = cast null;
		mPoolSize = 0;
		mBlockPool = new Array<Container<T>>();
	}
	
	/**
		Calls the `f` function on all elements.
		
		The function signature is: `f(element, xIndex, yIndex):element`
		<assert>`f` is null</assert>
	**/
	public function forEach(f:T->Int->T):ArrayedDeque<T>
	{
		var s = size;
		var i = mHead + 1;
		var j = i >> mBlockSizeShift;
		var k = 0;
		var b = mBlocks[j], bs = mBlockSize, blocks = mBlocks;
		i -= j << mBlockSizeShift;
		while (s > 0)
		{
			b.set(i, f(b.get(i), k++));
			if (++i == bs)
			{
				i = 0;
				b = blocks[++j];
			}
			s--;
		}
		return this;
	}
	
	/**
		Returns a string representing the current object.
		
		Example:
		<pre class="prettyprint">
		var deque = new de.polygonal.ds.ArrayedDeque<Int>();
		for (i in 0...4) {
		    deque.pushFront(i);
		}
		trace(deque);</pre>
		<pre class="console">
		{ ArrayedDeque size: 4 }
		[ front
		  0 -> 3
		  1 -> 2
		  2 -> 1
		  3 -> 0
		]</pre>
	**/
	public function toString():String
	{
		var s = '{ ArrayedDeque size: ${size} }';
		if (isEmpty()) return s;
		s += "\n[ front\n";
		
		var i = 0;
		if (mTailBlockIndex == 0)
		{
			for (j in mHead + 1...mTail)
				s += Printf.format("  %4d -> %s\n", [i++, Std.string(mHeadBlock[j])]);
		}
		else
		if (mTailBlockIndex == 1)
		{
			for (j in mHead + 1...mBlockSize)
				s += Printf.format("  %4d -> %s\n", [i++, Std.string(mHeadBlock[j])]);
			for (j in 0...mTail)
				s += Printf.format("  %4d -> %s\n", [i++, Std.string(mTailBlock[j])]);
		}
		else
		{
			for (j in mHead + 1...mBlockSize)
				s += Printf.format("  %4d -> %s\n", [i++, Std.string(mHeadBlock[j])]);
			
			for (j in 1...mTailBlockIndex)
			{
				var block = mBlocks[j];
				for (k in 0...mBlockSize)
					s += Printf.format("  %4d -> %s\n", [i++, Std.string(block[k])]);
			}
			
			for (j in 0...mTail)
				s += Printf.format("  %4d -> %s\n", [i++, Std.string(mTailBlock[j])]);
		}
		s += "]";
		return s;
	}
	
	/* INTERFACE Collection */
	
	/**
		The total number of elements.
	**/
	public var size(get, never):Int;
	function get_size():Int
	{
		return (mBlockSize - (mHead + 1)) + ((mTailBlockIndex - 1) << mBlockSizeShift) + mTail;
	}
	
	/**
		Destroys this object by explicitly nullifying all elements for GC'ing used resources.
		
		Improves GC efficiency/performance (optional).
	**/
	public function free()
	{
		for (i in 0...mTailBlockIndex + 1)
		{
			mBlocks[i].nullify();
			mBlocks[i] = null;
		}
		mBlocks = null;
		mHeadBlock = null;
		mHeadBlockNext = null;
		mTailBlock = null;
		mTailBlockPrev = null;
		if (mIterator != null)
		{
			mIterator.free();
			mIterator = null;
		}
	}
	
	/**
		Returns true if this deque contains the element `x`.
	**/
	public function contains(x:T):Bool
	{
		var i = 0;
		if (mTailBlockIndex == 0)
		{
			for (j in mHead + 1...mTail)
				if (mHeadBlock[j] == x) return true;
		}
		else
		if (mTailBlockIndex == 1)
		{
			for (j in mHead + 1...mBlockSize)
				if (mHeadBlock[j] == x) return true;
			for (j in 0...mTail)
				if (mTailBlock[j] == x) return true;
		}
		else
		{
			for (j in mHead + 1...mBlockSize)
				if (mHeadBlock[j] == x) return true;
			
			for (j in 1...mTailBlockIndex)
			{
				var block = mBlocks[j];
				for (k in 0...mBlockSize)
					if (block[k] == x) return true;
			}
			
			for (j in 0...mTail)
				if (mTailBlock[j] == x) return true;
		}
		return false;
	}
	
	/**
		Removes and nullifies all occurrences of the element `x`.
		@return true if at least one occurrence of `x` was removed.
	**/
	public function remove(x:T):Bool
	{
		var found = false;
		while (true)
		{
			var i =-1;
			var b = 0;
			
			if (mTailBlockIndex == 0)
			{
				for (j in mHead + 1...mTail)
				{
					if (mHeadBlock[j] == x)
					{
						i = j;
						break;
					}
				}
			}
			else
			if (mTailBlockIndex == 1)
			{
				for (j in mHead + 1...mBlockSize)
				{
					if (mHeadBlock[j] == x)
					{
						i = j;
						break;
					}
				}
				
				if (i == -1)
				{
					for (j in 0...mTail)
					{
						if (mTailBlock[j] == x)
						{
							i = j;
							b = 1;
							break;
						}
					}
				}
			}
			else
			{
				for (j in mHead + 1...mBlockSize)
				{
					if (mHeadBlock[j] == x)
					{
						i = j;
						break;
					}
				}
				
				if (i == -1)
				{
					for (j in 1...mTailBlockIndex)
					{
						var block = mBlocks[j];
						for (k in 0...mBlockSize)
						{
							if (block[k] == x)
							{
								i = k;
								b = j;
								break;
							}
						}
						if (i != -1) break;
					}
				}
				
				if (i == -1)
				{
					for (j in 0...mTail)
					{
						if (mTailBlock[j] == x)
						{
							i = j;
							b = mTailBlockIndex;
							break;
						}
					}
				}
			}
			
			if (i == -1)
			{
				found = true;
				break;
			}
			
			if (b == 0)
			{
				if (i == mHead + 1)
					mHead++;
				else
				if (i == mTail - 1)
					mTail--;
				else
				{
					var block = mBlocks[b];
					while (i > mHead + 1)
					{
						block[i] = block[i - 1];
						i--;
					}
					mHead++;
				}
			}
			else
			if (b == mTailBlockIndex)
			{
				while (i < mTail)
				{
					mTailBlock[i] = mTailBlock[i + 1];
					i++;
				}
				mTail--;
			}
			else
			{
				if (b <= mTailBlockIndex - b)
				{
					var block = mBlocks[b];
					while (i > 0)
					{
						block[i] = block[i - 1];
						i--;
					}
					
					while (b > 1)
					{
						var prevBlock = mBlocks[b - 1];
						block[0] = prevBlock[mBlockSizeMinusOne];
						block = prevBlock;
						
						i = mBlockSizeMinusOne;
						while (i > 0)
						{
							block[i] = block[i - 1];
							i--;
						}
						
						b--;
					}
					
					block[0] = mHeadBlock[mBlockSizeMinusOne];
					i = mBlockSizeMinusOne;
					var j = mHead + 1;
					while (i > j)
					{
						mHeadBlock[i] = mHeadBlock[i - 1];
						i--;
					}
					if (++mHead == mBlockSize) shiftBlock();
				}
				else
				{
					var block = mBlocks[b];
					
					while (i < mBlockSize - 1)
					{
						block[i] = block[i + 1];
						i++;
					}
					
					var j = mTailBlockIndex - 1;
					while (b < j)
					{
						var nextBlock = mBlocks[b + 1];
						block[mBlockSizeMinusOne] = nextBlock[0];
						block = nextBlock;
						
						i = 0;
						while (i < mBlockSizeMinusOne)
						{
							block[i] = block[i + 1];
							i++;
						}
						
						b++;
					}
					
					block[mBlockSizeMinusOne] = mTailBlock[0];
					i = 0;
					var j = mTail - 1;
					while (i < j)
					{
						mTailBlock[i] = mTailBlock[i + 1];
						i++;
					}
					if (--mTail < 0) popBlock();
				}
			}
		}
		return found;
	}
	
	/**
		Removes all elements.
		
		@param gc if true, elements are nullified upon removal so the garbage collector can reclaim used memory.
	**/
	public function clear(gc:Bool = false)
	{
		if (gc)
		{
			for (i in 0...mTailBlockIndex + 1)
			{
				var block = mBlocks[i];
				for (j in 0...mBlockSize) block.set(j, cast null);
				mBlocks[i] = null;
			}
			mBlocks = new Array();
			mBlocks[0] = NativeArrayTools.init(mBlockSize);
			mHeadBlock = mBlocks[0];
			for (i in 0...mBlockPool.length)
				mBlockPool[i] = null;
			mBlockPool = new Array<Container<T>>();
			mPoolSize = 0;
		}
		
		mHead = 0;
		mTail = 1;
		mTailBlockIndex = 0;
		mTailBlock = mHeadBlock;
		mHeadBlockNext = null;
		mTailBlockPrev = null;
	}
	
	/**
		Returns a new `ArrayedDequeIterator` object to iterate over all elements contained in this deque.
		
		Preserves the natural order of a deque.
		
		See <a href="http://haxe.org/ref/iterators" target="mBlank">http://haxe.org/ref/iterators</a>
	**/
	public function iterator():Itr<T>
	{
		if (reuseIterator)
		{
			if (mIterator == null)
				mIterator = new ArrayedDequeIterator<T>(this);
			else
				mIterator.reset();
			return mIterator;
		}
		else
			return new ArrayedDequeIterator<T>(this);
	}
	
	/**
		Returns true if this deque is empty.
	**/
	public inline function isEmpty():Bool
	{
		if (mTailBlockIndex == 0)
			return (mTail - mHead) == 1;
		else
			return mHead == mBlockSizeMinusOne && mTail == 0;
	}
	
	/**
		Returns an array containing all elements in this deque in the natural order.
	**/
	public function toArray():Array<T>
	{
		if (isEmpty()) return [];
		
		var out = ArrayTools.alloc(size);
		var i = 0;
		if (mTailBlockIndex == 0)
		{
			for (j in mHead + 1...mTail) out[i++] = mHeadBlock[j];
		}
		else
		if (mTailBlockIndex == 1)
		{
			for (j in mHead + 1...mBlockSize) out[i++] = mHeadBlock[j];
			for (j in 0...mTail) out[i++] = mTailBlock[j];
		}
		else
		{
			for (j in mHead + 1...mBlockSize) out[i++] = mHeadBlock[j];
			for (j in 1...mTailBlockIndex)
			{
				var block = mBlocks[j];
				for (k in 0...mBlockSize) out[i++] = block[k];
			}
			for (j in 0...mTail) out[i++] = mTailBlock[j];
		}
		return out;
	}
	
	/**
		Duplicates this deque. Supports shallow (structure only) and deep copies (structure & elements).
		<assert>element is not of type `Cloneable`</assert>
		@param assign if true, the `copier` parameter is ignored and primitive elements are copied by value whereas objects are copied by reference.
		If false, the ``clone()`` method is called on each element. <warn>In this case all elements have to implement `Cloneable`.</warn>
		@param copier a custom function for copying elements. Replaces ``element::clone()`` if `assign` is false.
	**/
	public function clone(assign:Bool = true, copier:T->T = null):Collection<T>
	{
		var c = new ArrayedDeque<T>(M.INT16_MIN);
		c.mBlockSize = mBlockSize;
		c.mBlockSizeMinusOne = mBlockSizeMinusOne;
		c.mHead = mHead;
		c.mTail = mTail;
		c.mTailBlockIndex = mTailBlockIndex;
		c.mBlockSizeShift = mBlockSizeShift;
		c.mPoolSize = 0;
		c.mPoolCapacity = 0;
		
		var blocks = c.mBlocks = ArrayTools.alloc(mTailBlockIndex + 1);
		for (i in 0...mTailBlockIndex + 1)
			blocks[i] = NativeArrayTools.init(mBlockSize);
		c.mHeadBlock = blocks[0];
		c.mTailBlock = blocks[mTailBlockIndex];
		if (mTailBlockIndex > 0)
		{
			c.mHeadBlockNext = blocks[1];
			c.mTailBlockPrev = blocks[mTailBlockIndex - 1];
		}
		
		if (assign)
		{
			if (mTailBlockIndex == 0)
				copy(mHeadBlock, c.mHeadBlock, mHead + 1, mTail);
			else
			if (mTailBlockIndex == 1)
			{
				copy(mHeadBlock, c.mHeadBlock, mHead + 1, mBlockSize);
				copy(mTailBlock, c.mTailBlock, 0, mTail);
			}
			else
			{
				copy(mHeadBlock, c.mHeadBlock, mHead + 1, mBlockSize);
				for (j in 1...mTailBlockIndex)
					copy(mBlocks[j], blocks[j], 0, mBlockSize);
				copy(mTailBlock, c.mTailBlock, 0, mTail);
			}
		}
		else
		{
			if (copier != null)
			{
				if (mTailBlockIndex == 0)
					copyCopier(copier, mHeadBlock, c.mHeadBlock, mHead + 1, mTail);
				else
				if (mTailBlockIndex == 1)
				{
					copyCopier(copier,mHeadBlock, c.mHeadBlock, mHead + 1, mBlockSize);
					copyCopier(copier,mTailBlock, c.mTailBlock, 0, mTail);
				}
				else
				{
					copyCopier(copier,mHeadBlock, c.mHeadBlock, mHead + 1, mBlockSize);
					for (j in 1...mTailBlockIndex)
						copyCopier(copier,mBlocks[j], blocks[j], 0, mBlockSize);
					copyCopier(copier, mTailBlock, c.mTailBlock, 0, mTail);
				}
			}
			else
			{
				if (mTailBlockIndex == 0)
					copyCloneable(mHeadBlock, c.mHeadBlock, mHead + 1, mTail);
				else
				if (mTailBlockIndex == 1)
				{
					copyCloneable(mHeadBlock, c.mHeadBlock, mHead + 1, mBlockSize);
					copyCloneable(mTailBlock, c.mTailBlock, 0, mTail);
				}
				else
				{
					copyCloneable(mHeadBlock, c.mHeadBlock, mHead + 1, mBlockSize);
					for (j in 1...mTailBlockIndex)
						copyCloneable(mBlocks[j], blocks[j], 0, mBlockSize);
					copyCloneable(mTailBlock, c.mTailBlock, 0, mTail);
				}
			}
		}
		return c;
	}
	
	function shiftBlock()
	{
		putBlock(mBlocks[0]);
		mBlocks.shift();
		mHead = 0;
		mHeadBlock = mHeadBlockNext;
		mTailBlock = mBlocks[--mTailBlockIndex];
		if (mTailBlockIndex > 0)
		{
			mHeadBlockNext = mBlocks[1];
			mTailBlockPrev = mBlocks[mTailBlockIndex - 1];
		}
		else
		{
			mHeadBlockNext = null;
			mTailBlockPrev = null;
		}
	}
	
	function unshiftBlock()
	{
		mBlocks.unshift(getBlock());
		mHead = mBlockSizeMinusOne;
		mHeadBlock = mBlocks[0];
		mHeadBlockNext = mBlocks[1];
		mTailBlockPrev = mBlocks[mTailBlockIndex++];
		mTailBlock = mBlocks[mTailBlockIndex];
	}
	
	function popBlock()
	{
		putBlock(mBlocks.pop());
		mTailBlockIndex--;
		mTailBlock = mTailBlockPrev;
		mTail = mBlockSizeMinusOne;
		if (mTailBlockIndex > 0)
			mTailBlockPrev = mBlocks[mTailBlockIndex - 1];
		else
		{
			mHeadBlockNext = null;
			mTailBlockPrev = null;
		}
	}
	
	function pushBlock()
	{
		mBlocks.push(getBlock());
		mTail = 0;
		mTailBlockPrev = mTailBlock;
		mTailBlock = mBlocks[++mTailBlockIndex];
		if (mTailBlockIndex == 1)
			mHeadBlockNext = mBlocks[1];
	}
	
	inline function getBlock():Container<T>
	{
		if (mPoolSize > 0)
			return mBlockPool[--mPoolSize];
		else
			return NativeArrayTools.init(mBlockSize);
	}
	
	inline function putBlock(x:Container<T>)
	{
		if (mPoolSize < mPoolCapacity)
			mBlockPool[mPoolSize++] = x;
	}
	
	inline function copy(src:Container<T>, dst:Container<T>, min:Int, max:Int)
	{
		for (j in min...max)
			dst[j] = src[j];
	}
	
	inline function copyCloneable(src:Container<T>, dst:Container<T>, min:Int, max:Int)
	{
		for (j in min...max)
		{
			assert(Std.is(src[j], Cloneable), 'element is not of type Cloneable (${src[j]})');
			
			dst[j] = src[j];
		}
	}
	
	inline function copyCopier(copier:T->T, src:Container<T>, dst:Container<T>, min:Int, max:Int)
	{
		for (j in min...max)
			dst[j] = copier(src[j]);
	}
}

#if generic
@:generic
#end
@:access(de.polygonal.ds.ArrayedDeque)
@:dox(hide)
class ArrayedDequeIterator<T> implements de.polygonal.ds.Itr<T>
{
	var mObject:ArrayedDeque<T>;
	var mBlocks:Array<Container<T>>;
	var mBlock:Container<T>;
	var mI:Int;
	var mS:Int;
	var mB:Int;
	var mBlockSize:Int;
	
	public function new(x:ArrayedDeque<T>)
	{
		mObject = x;
		reset();
	}
	
	public function free()
	{
		mObject = null;
		mBlocks = null;
		mBlock = null;
	}
	
	public function reset():Itr<T>
	{
		mBlockSize = mObject.mBlockSize;
		mBlocks = mObject.mBlocks;
		mI = mObject.mHead + 1;
		mB = mI >> mObject.mBlockSizeShift;
		mS = mObject.size;
		mBlock = mBlocks[mB];
		mI -= mB << mObject.mBlockSizeShift;
		return this;
	}
	
	public inline function hasNext():Bool
	{
		return mS > 0;
	}
	
	public inline function next():T
	{
		var x = mBlock.get(mI++);
		if (mI == mBlockSize)
		{
			mI = 0;
			mBlock = mBlocks[++mB];
		}
		mS--;
		return x;
	}
	
	public function remove()
	{
		throw "unsupported operation";
	}
}