/*
 * Copyright 2004-2017 Cray Inc.
 * Other additional copyright holders may be indicated within.
 * 
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * 
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//
// The SparseBlock distribution is defined with six classes:
//
//   Block             : (from BlockDist) distribution class
//   SparseBlockDom    : domain class
//   SparseBlockArr    : array class
//   LocSparseBlockDom : local domain class (per-locale instances)
//   LocSparseBlockArr : local array class (per-locale instances)
//
// When a distribution, domain, or array class instance is created, a
// corresponding local class instance is created on each locale that is
// mapped to by the distribution.
//

use DSIUtil;
use ChapelUtil;
use BlockDist;
//
// These flags are used to output debug information and run extra
// checks when using SparseBlock.  Should these be promoted so that they can
// be used across all distributions?  This can be done by turning them
// into compiler flags or adding config parameters to the internal
// modules, perhaps called debugDists and checkDists.
//
config param debugSparseBlockDist = false;
config param debugSparseBlockDistBulkTransfer = false;
// There is no SparseBlock distribution class. Instead, we
// just use Block.

//
// SparseBlock Domain Class
//
// rank:      generic domain rank
// idxType:   generic domain index type
// stridable: generic domain stridable parameter
// dist:      reference to distribution class
// locDoms:   a non-distributed array of local domain classes
// whole:     a non-distributed domain that defines the domain's indices
//
class SparseBlockDom: BaseSparseDomImpl {
  type sparseLayoutType;
  param stridable: bool = false;  // TODO: remove default value eventually
  const dist: Block(rank, idxType, sparseLayoutType);
  const whole: domain(rank=rank, idxType=idxType, stridable=stridable);
  var locDoms: [dist.targetLocDom] LocSparseBlockDom(rank, idxType, stridable,
      sparseLayoutType);

  proc initialize() {
    setup();
    //    writeln("Exiting initialize");
  }

  proc setup() {
    //    writeln("In setup");
    if locDoms(dist.targetLocDom.low) == nil {
      coforall localeIdx in dist.targetLocDom do {
        on dist.targetLocales(localeIdx) do {
          //                    writeln("Setting up on ", here.id);
          //                    writeln("setting up on ", localeIdx, ", whole is: ", whole, ", chunk is: ", dist.getChunk(whole,localeIdx));
         locDoms(localeIdx) = new LocSparseBlockDom(rank, idxType, stridable,
             sparseLayoutType, dist.getChunk(whole,localeIdx));
          //                    writeln("Back on ", here.id);
        }
      }
      //      writeln("Past coforall");
    } else {
      halt("Don't know how to reallocate yet");
      /*
      coforall localeIdx in dist.targetLocDom do {
        on dist.targetLocales(localeIdx) do
          locDoms(localeIdx).mySparseBlock = dist.getChunk(whole, localeIdx);
      }
      */
    }
    //    writeln("Exiting setup()");
  }

  // TODO: For some reason I have to make all the methods for these classes primary
  // rather than secondary methods.  This doesn't seem right, but I couldn't boil
  // it down to a smaller test case in the time I spent on it.
  proc dsiAdd(ind: rank*idxType) {
    var _retval = 0;
    on dist.dsiIndexToLocale(ind) {
      _retval = locDoms[dist.targetLocsIdx(ind)].dsiAdd(ind);
    }
    nnz += _retval;
    return _retval;
  }

  proc dsiAdd(ind: idxType) where this.rank == 1 {
    return dsiAdd((ind,));
  }

  proc dsiFirst {
    return min reduce ([l in locDoms] l.mySparseBlock.first);
  }

  proc dsiLast {
    return max reduce ([l in locDoms] l.mySparseBlock.last);
  }

  // Tried to put this record in the function and the if statement, but got a
  // segfault from the compiler.
  record TargetLocaleComparator {
    proc key(a: index(rank, idxType)) { 
      return (dist.targetLocsIdx(a), a);
    }
  }

  proc bulkAdd_help(inds: [] index(rank,idxType),
      dataSorted=false, isUnique=false) {
    use Sort;
    use Search;

    // without _new_, record functions throw null deref
    var comp = new TargetLocaleComparator();

    if !dataSorted then sort(inds, comparator=comp);

    var localeRanges: [dist.targetLocDom] range;
    on inds {
      for l in dist.targetLocDom {
        const _first = locDoms[l].mySparseBlock._value.parentDom.first;
        const _last = locDoms[l].mySparseBlock._value.parentDom.last;

        var (foundFirst, locFirst) = binarySearch(inds, _first, comp);
        var (foundLast, locLast) = binarySearch(inds, _last, comp);

        if !foundLast then locLast -= 1;

        // two ifs are necessary to catch out of bounds in the bulkAdd call
        // chain. otherwise this methods would cutoff indices that are smaller
        // than parentDom.first or larger than parentDom.last, which is
        // _probably_ not desirable.
        if dist.targetLocDom.first == l then
          locFirst = inds.domain.first;
        if dist.targetLocDom.last == l then
          locLast = inds.domain.last;

        localeRanges[l] = locFirst..locLast;
      }
    }
    var _totalAdded: atomic int;
    coforall l in dist.targetLocDom do on dist.targetLocales[l] {
      const _retval = locDoms[l].mySparseBlock.bulkAdd(inds[localeRanges[l]],
          dataSorted=true, isUnique=false);
      _totalAdded.add(_retval);
    }
    const _retval = _totalAdded.read();
    nnz += _retval;
    return _retval;
  }

  //
  // output domain
  //
  proc dsiSerialWrite(f) {
    if (rank == 1) {
      f.write("{");
      for locdom in locDoms do {
        // on locdom do {
        if (locdom.dsiNumIndices) {
            f.write(" ");
            locdom.dsiSerialWrite(f);
          }
          //}
      }
      f.write("}");
    } else {
      compilerError("Can't write out multidimensional sparse distributed domains yet");
    }
  }

  //
  // how to allocate a new array over this domain
  //
  proc dsiBuildArray(type eltType) {
    var arr = new SparseBlockArr(eltType=eltType, rank=rank, idxType=idxType,
        stridable=stridable, sparseLayoutType=sparseLayoutType, dom=this);
    arr.setup();
    return arr;
  }

  // stopgap to avoid accessing locDoms field (and returning an array)
  proc getLocDom(localeIdx) return locDoms(localeIdx);

  iter these() {
    for locDom in locDoms do
      // TODO Would want to do something like:
      //on blk do
      // But can't currently have yields in on clauses:
      // invalid use of 'yield' within 'on' in serial iterator
      for x in locDom.mySparseBlock._value.these() do
        yield x;
  }

  iter these(param tag: iterKind) where tag == iterKind.leader {
    coforall (locDom,localeIndex) in zip(locDoms,dist.targetLocDom) {
      on locDom {
        for followThis in locDom.mySparseBlock._value.these(tag) {
          yield (followThis, localeIndex);
        }
      }
    }
  }

  iter these(param tag: iterKind, followThis) where tag == iterKind.follower {
    var (locFollowThis, localeIndex) = followThis;
    for i in locFollowThis(1).these(tag, locFollowThis) do
      yield i;
  }

  iter these(param tag: iterKind) where tag == iterKind.standalone {
    coforall locDom in locDoms {
      on locDom {
        for i in locDom.mySparseBlock._value.these(tag) {
          yield i;
        }
      }
    }
  }

  proc dsiMember(ind) {
    on whole.dist.idxToLocale(ind) {
      writeln("Need to add support for mapping locale to local domain");
    }
  }

  proc dsiClear() {
    nnz = 0;
    coforall locDom in locDoms do
      on locDom do
        locDom.dsiClear();
  }

  proc dsiMyDist() return dist;
}

//
// Local SparseBlock Domain Class
//
// rank: generic domain rank
// idxType: generic domain index type
// stridable: generic domain stridable parameter
// mySparseBlock: a non-distributed domain that defines the local indices
//
class LocSparseBlockDom {
  param rank: int;
  type idxType;
  param stridable: bool;
  type sparseLayoutType;
  var parentDom: domain(rank, idxType, stridable);
  var sparseDist = new sparseLayoutType; //unresolved call workaround
  var mySparseBlock: sparse subdomain(parentDom) dmapped new dmap(sparseDist);

  proc initialize() {
    //    writeln("On locale ", here.id, " LocSparseBlockDom = ", this);
  }

  proc dsiAdd(ind: rank*idxType) {
    return mySparseBlock.add(ind);
  }

  proc dsiMember(ind: rank*idxType) {
    return mySparseBlock.member(ind);
  }

  proc dsiClear() {
    mySparseBlock.clear();
  }

  proc dsiSerialWrite(w) {
    mySparseBlock._value.dsiSerialWrite(w, printBrackets=false);
    // w.write(mySparseBlock); // works, but gets brackets printed out redundantly
    //    w <~> mySparseBlock;
  }

  proc dsiNumIndices {
    return mySparseBlock.numIndices;
  }
}

//
// SparseBlock Array Class
//
// eltType: generic array element type
// rank: generic array rank
// idxType: generic array index type
// stridable: generic array stridable parameter
// dom: reference to domain class
// locArr: a non-distributed array of local array classes
// myLocArr: optimized reference to here's local array class (or nil)
//
class SparseBlockArr: BaseSparseArr {
  param stridable: bool;
  type sparseLayoutType = DefaultDist;

  // ideally I wanted to have `var locArr: [dom.dist.targetLocDom]`. However,
  // superclass' fields cannot be used in child class' field initializers. See
  // the constructor for the workaround.
  var locArrDom: domain(rank,idxType);
  var locArr: [locArrDom] LocSparseBlockArr(eltType, rank, idxType, stridable,
      sparseLayoutType);
  var myLocArr: LocSparseBlockArr(eltType, rank, idxType, stridable,
      sparseLayoutType);

  proc SparseBlockArr(type eltType, param rank, type idxType, param stridable,
      type sparseLayoutType ,dom) {
    locArrDom = dom.dist.targetLocDom;
  }

  proc setup() {
    var thisid = this.locale.id;
    coforall localeIdx in dom.dist.targetLocDom {
      on dom.dist.targetLocales(localeIdx) {
        const locDom = dom.getLocDom(localeIdx);
        locArr(localeIdx) = new LocSparseBlockArr(eltType, rank, idxType,
            stridable, sparseLayoutType, locDom);
        if thisid == here.id then
          myLocArr = locArr(localeIdx);
      }
    }
  }

  iter these() ref {
    for locI in dom.dist.targetLocDom {
      // TODO Would want to do something like:
      //on locDom do
      // But can't currently have yields in on clauses:
      // invalid use of 'yield' within 'on' in serial iterator
      var locDom = dom.locDoms[locI];
      var locArrI = locArr[locI];
      for x in locDom.mySparseBlock {
        yield locArrI.myElems(x);
      }
    }
  }

  iter these(param tag: iterKind) where tag == iterKind.leader {
    for followThis in dom.these(tag) do
      yield followThis;
  }

  iter these(param tag: iterKind, followThis) ref where tag == iterKind.follower {
    var (locFollowThis, localeIndex) = followThis;
    for i in locFollowThis(1).these(tag, locFollowThis) {
      yield locArr[localeIndex].dsiAccess(i);
    }
  }

  iter these(param tag: iterKind) ref where tag == iterKind.standalone {
    coforall locA in locArr do on locArr {
      // forward to sparse standalone iterator
      for i in locA.myElems._value.these(tag) {
        yield i;
      }
    }
  }


  proc dsiAccess(i: rank*idxType) ref {
    //    local { // TODO: Turn back on once privatization is on
      if myLocArr != nil && myLocArr.locDom.dsiMember(i) {
        return myLocArr.dsiAccess(i);
        //      }
    }
    return locArr[dom.dist.targetLocsIdx(i)].dsiAccess(i);
  }
  proc dsiAccess(i: rank*idxType)
  where !shouldReturnRvalueByConstRef(eltType) {
    //    local { // TODO: Turn back on once privatization is on
      if myLocArr != nil && myLocArr.locDom.dsiMember(i) {
        return myLocArr.dsiAccess(i);
        //      }
    }
    return locArr[dom.dist.targetLocsIdx(i)].dsiAccess(i);
  }
  proc dsiAccess(i: rank*idxType) const ref
  where shouldReturnRvalueByConstRef(eltType) {
    //    local { // TODO: Turn back on once privatization is on
      if myLocArr != nil && myLocArr.locDom.dsiMember(i) {
        return myLocArr.dsiAccess(i);
        //      }
    }
    return locArr[dom.dist.targetLocsIdx(i)].dsiAccess(i);
  }




  proc dsiAccess(i: idxType...rank) ref
    return dsiAccess(i);
  proc dsiAccess(i: idxType...rank)
  where !shouldReturnRvalueByConstRef(eltType)
    return dsiAccess(i);
  proc dsiAccess(i: idxType...rank) const ref
  where shouldReturnRvalueByConstRef(eltType)
    return dsiAccess(i);



  proc dsiGetBaseDom() return dom;

}

//
// Local SparseBlock Array Class
//
// eltType: generic array element type
// rank: generic array rank
// idxType: generic array index type
// stridable: generic array stridable parameter
// locDom: reference to local domain class
// myElems: a non-distributed array of local elements
//
class LocSparseBlockArr {
  type eltType;
  param rank: int;
  type idxType;
  param stridable: bool;
  type sparseLayoutType;
  const locDom: LocSparseBlockDom(rank, idxType, stridable, sparseLayoutType);
  var myElems: [locDom.mySparseBlock] eltType;

  proc dsiAccess(i) ref {
    return myElems[i];
  }
  proc dsiAccess(i)
  where !shouldReturnRvalueByConstRef(eltType) {
    return myElems[i];
  }
  proc dsiAccess(i) const ref
  where shouldReturnRvalueByConstRef(eltType) {
    return myElems[i];
  }
}

/*

Some old code that might be useful to draw from as this
module is improved.

proc SparseBlockDom.dsiNewSpsSubDom(parentDomVal) {
  return new SparseBlockDom(rank, idxType, dist, parentDomVal);
}

proc SparseBlockDom.dsiDisplayRepresentation() {
  writeln("whole = ", whole);
  for tli in dist.targetLocDom do
    writeln("locDoms[", tli, "].mySparseBlock = ", locDoms[tli].mySparseBlock);
}



//
// Given a tuple of scalars of type t or range(t) match the shape but
// using types rangeType and scalarType e.g. the call:
// _matchArgsShape(range(int(32)), int(32), (1:int(64), 1:int(64)..5, 1:int(64)..5))
// returns the type: (int(32), range(int(32)), range(int(32)))
//
proc _matchArgsShape(type rangeType, type scalarType, args) type {
  proc tuple(type t ...) type return t;
  proc helper(param i: int) type {
    if i == args.size {
      if isCollapsedDimension(args(i)) then
        return tuple(scalarType);
      else
        return tuple(rangeType);
    } else {
      if isCollapsedDimension(args(i)) then
        return (scalarType, (... helper(i+1)));
      else
        return (rangeType, (... helper(i+1)));
    }
  }
  return helper(1);
}


proc SparseBlock.dsiCreateRankChangeDist(param newRank: int, args) {
  var collapsedDimLocs: rank*idxType;

  for param i in 1..rank {
    if isCollapsedDimension(args(i)) {
      collapsedDimLocs(i) = args(i);
    } else {
      collapsedDimLocs(i) = 0;
    }
  }
  const collapsedLocInd = targetLocsIdx(collapsedDimLocs);
  var collapsedBbox: _matchArgsShape(range(idxType=idxType), idxType, args);
  var collapsedLocs: _matchArgsShape(range(idxType=int), int, args);

  for param i in 1..rank {
    if isCollapsedDimension(args(i)) {
      // set indices that are out of bounds to the bounding box low or high.
      collapsedBbox(i) = if args(i) < boundingBox.dim(i).low then boundingBox.dim(i).low else if args(i) > boundingBox.dim(i).high then boundingBox.dim(i).high else args(i);
      collapsedLocs(i) = collapsedLocInd(i);
    } else {
      collapsedBbox(i) = boundingBox.dim(i);
      collapsedLocs(i) = targetLocDom.dim(i);
    }
  }

  const newBbox = boundingBox[(...collapsedBbox)];
  const newTargetLocales = targetLocales((...collapsedLocs));
  return new SparseBlock(newBbox, newTargetLocales,
                   dataParTasksPerLocale, dataParIgnoreRunningTasks,
                   dataParMinGranularity);
}

proc SparseBlockDom.dsiLow return whole.low;
proc SparseBlockDom.dsiHigh return whole.high;
proc SparseBlockDom.dsiStride return whole.stride;

//
// INTERFACE NOTES: Could we make dsiSetIndices() for a rectangular
// domain take a domain rather than something else?
//
proc SparseBlockDom.dsiSetIndices(x: domain) {
  if x.rank != rank then
    compilerError("rank mismatch in domain assignment");
  if x._value.idxType != idxType then
    compilerError("index type mismatch in domain assignment");
  whole = x;
  setup();
  if debugSparseBlockDist {
    writeln("Setting indices of SparseBlock domain:");
    dsiDisplayRepresentation();
  }
}

proc SparseBlockDom.dsiSetIndices(x) {
  if x.size != rank then
    compilerError("rank mismatch in domain assignment");
  if x(1).idxType != idxType then
    compilerError("index type mismatch in domain assignment");
  //
  // TODO: This seems weird:
  //
  whole.setIndices(x);
  setup();
  if debugSparseBlockDist {
    writeln("Setting indices of SparseBlock domain:");
    dsiDisplayRepresentation();
  }
}

proc SparseBlockDom.dsiGetIndices() {
  return whole.getIndices();
}

// dsiLocalSlice
proc SparseBlockDom.dsiLocalSlice(param stridable: bool, ranges) {
  return whole((...ranges));
}

proc SparseBlockDom.dsiIndexOrder(i) {
  return whole.indexOrder(i);
}

//
// build a new rectangular domain using the given range
//
proc SparseBlockDom.dsiBuildRectangularDom(param rank: int, type idxType,
                                   param stridable: bool,
                                   ranges: rank*range(idxType,
                                                      BoundedRangeType.bounded,
                                                      stridable)) {
  if idxType != dist.idxType then
    compilerError("SparseBlock domain index type does not match distribution's");
  if rank != dist.rank then
    compilerError("SparseBlock domain rank does not match distribution's");

  var dom = new SparseBlockDom(rank=rank, idxType=idxType,
                         dist=dist, stridable=stridable);
  dom.dsiSetIndices(ranges);
  return dom;
}

//
// Added as a performance stopgap to avoid returning a domain
//
proc LocSparseBlockDom.member(i) return mySparseBlock.member(i);

proc SparseBlockArr.dsiDisplayRepresentation() {
  for tli in dom.dist.targetLocDom {
    writeln("locArr[", tli, "].myElems = ", for e in locArr[tli].myElems do e);
  }
}

inline proc _remoteAccessData.getDataIndex(param stridable, ind: rank*idxType) {
  // modified from DefaultRectangularArr below
  var sum = origin;
  if stridable {
    for param i in 1..rank do
      sum += (ind(i) - off(i)) * blk(i) / abs(str(i)):idxType;
  } else {
    for param i in 1..rank do
      sum += ind(i) * blk(i);
    sum -= factoredOffs;
  }
  return sum;
}

proc SparseBlockArr.dsiSlice(d: SparseBlockDom) {
  var alias = new SparseBlockArr(eltType=eltType, rank=rank, idxType=idxType, stridable=d.stridable, dom=d, pid=pid);
  var thisid = this.locale.id;
  coforall i in d.dist.targetLocDom {
    on d.dist.targetLocales(i) {
      alias.locArr[i] = new LocSparseBlockArr(eltType=eltType, rank=rank, idxType=idxType, stridable=d.stridable, locDom=d.locDoms[i], myElems=>locArr[i].myElems[d.locDoms[i].mySparseBlock]);
      if thisid == here.id then
        alias.myLocArr = alias.locArr[i];
    }
  }
  return alias;
}

proc SparseBlockArr.dsiLocalSlice(ranges) {
  var low: rank*idxType;
  for param i in 1..rank {
    low(i) = ranges(i).low;
  }
  return locArr(dom.dist.targetLocsIdx(low)).myElems((...ranges));
}

proc _extendTuple(type t, idx: _tuple, args) {
  var tup: args.size*t;
  var j: int = 1;

  for param i in 1..args.size {
    if isCollapsedDimension(args(i)) then
      tup(i) = args(i);
    else {
      tup(i) = idx(j);
      j += 1;
    }
  }
  return tup;
}

proc _extendTuple(type t, idx, args) {
  var tup: args.size*t;
  var idxTup = tuple(idx);
  var j: int = 1;

  for param i in 1..args.size {
    if isCollapsedDimension(args(i)) then
      tup(i) = args(i);
    else {
      tup(i) = idxTup(j);
      j += 1;
    }
  }
  return tup;
}


proc SparseBlockArr.dsiRankChange(d, param newRank: int, param stridable: bool, args) {
  var alias = new SparseBlockArr(eltType=eltType, rank=newRank, idxType=idxType, stridable=stridable, dom=d);
  var thisid = this.locale.id;
  coforall ind in d.dist.targetLocDom {
    on d.dist.targetLocales(ind) {
      const locDom = d.getLocDom(ind);
      // locSlice is a tuple of ranges and scalars. It will match the basic
      // shape of the args argument.
      var locSlice: _matchArgsShape(range(idxType=idxType, stridable=stridable), idxType, args);
      // collapsedDims stores the value any collapsed dimension is down to.
      // For any non-collapsed dimension, that position is ignored.
      // This tuple is then passed to the targetLocsIdx function to build up a
      // partial index into this.targetLocDom with correct values set for all
      // collapsed dimensions. The rest of the dimensions get their values from
      // ind - an index into the new rank changed targetLocDom.
      var collapsedDims: rank*idxType;
      var locArrInd: rank*int;

      var j = 1;
      for param i in 1..args.size {
        if isCollapsedDimension(args(i)) {
          locSlice(i) = args(i);
          collapsedDims(i) = args(i);
        } else {
          locSlice(i) = locDom.mySparseBlock.dim(j)(args(i));
          j += 1;
        }
      }
      locArrInd = dom.dist.targetLocsIdx(collapsedDims);
      j = 1;
      // Now that the locArrInd values are known for the collapsed dimensions
      // Pull the rest of the dimensions values from ind
      for param i in 1..args.size {
        if !isCollapsedDimension(args(i)) {
          if newRank > 1 then
            locArrInd(i) = ind(j);
          else
            locArrInd(i) = ind;
          j += 1;
        }
      }

      alias.locArr[ind] =
        new LocSparseBlockArr(eltType=eltType, rank=newRank, idxType=d.idxType,
                        stridable=d.stridable, locDom=locDom,
                        myElems=>locArr[(...locArrInd)].myElems[(...locSlice)]);

      if thisid == here.id then
        alias.myLocArr = alias.locArr[ind];
    }
  }
  return alias;
}

proc SparseBlockArr.dsiReindex(d: SparseBlockDom) {
  var alias = new SparseBlockArr(eltType=eltType, rank=d.rank, idxType=d.idxType,
                           stridable=d.stridable, dom=d);
  const sameDom = d==dom;

  var thisid = this.locale.id;
  coforall i in d.dist.targetLocDom {
    on d.dist.targetLocales(i) {
      const locDom = d.getLocDom(i);
      var locAlias: [locDom.mySparseBlock] => locArr[i].myElems;
      alias.locArr[i] = new LocSparseBlockArr(eltType=eltType,
                                        rank=rank, idxType=d.idxType,
                                        stridable=d.stridable,
                                        locDom=locDom,
                                        myElems=>locAlias);
      if thisid == here.id then
        alias.myLocArr = alias.locArr[i];
      }
    }
  }

  return alias;
}

proc SparseBlockArr.dsiReallocate(d: domain) {
  //
  // For the default rectangular array, this function changes the data
  // vector in the array class so that it is setup once the default
  // rectangular domain is changed.  For this distributed array class,
  // we don't need to do anything, because changing the domain will
  // change the domain in the local array class which will change the
  // data in the local array class.  This will only work if the domain
  // we are reallocating to has the same distribution, but domain
  // assignment is defined so that only the indices are transferred.
  // The distribution remains unchanged.
  //
}

proc SparseBlockArr.dsiPostReallocate() {
  // Call this *after* the domain has been reallocated
}

//
// the accessor for the local array -- assumes the index is local
//
proc LocSparseBlockArr.this(i) ref {
  return myElems(i);
}

*/

//
// output array
//
proc SparseBlockArr.dsiSerialWrite(f) {
  if (rank == 1) {
    f.write("[");
    for locarr in locArr do {
      // on locdom do {
      if (locarr.locDom.dsiNumIndices) {
        f.write(" ");
        locarr.dsiSerialWrite(f);
      }
      // }
    }
    f.write("]");
  } else {
    compilerError("Can't write out multidimensional sparse distributed arrays yet");
  }
}

proc LocSparseBlockArr.dsiSerialWrite(f) {
  myElems._value.dsiSerialWrite(f);
}


proc SparseBlockDom.dsiSupportsPrivatization() param return false;

proc SparseBlockDom.dsiGetPrivatizeData() return (dist.pid, whole.dims());

proc SparseBlockDom.dsiPrivatize(privatizeData) {
  var privdist = chpl_getPrivatizedCopy(dist.type, privatizeData(1));
  var c = new SparseBlockDom(rank=rank, idxType=idxType, stridable=stridable,
      dist=privdist, whole=whole);
  for i in c.dist.targetLocDom do
    c.locDoms(i) = locDoms(i);
  c.whole = {(...privatizeData(2))};
  return c;
}

proc SparseBlockDom.dsiGetReprivatizeData() return whole.dims();

proc SparseBlockDom.dsiReprivatize(other, reprivatizeData) {
  for i in dist.targetLocDom do
    locDoms(i) = other.locDoms(i);
  whole = {(...reprivatizeData)};
}

proc SparseBlockArr.dsiSupportsPrivatization() param return false;

proc SparseBlockArr.dsiGetPrivatizeData() return dom.pid;

proc SparseBlockArr.dsiPrivatize(privatizeData) {
  var privdom = chpl_getPrivatizedCopy(dom.type, privatizeData);
  var c = new SparseBlockArr(eltType=eltType, rank=rank, idxType=idxType, stridable=stridable, dom=privdom);
  for localeIdx in c.dom.dist.targetLocDom {
    c.locArr(localeIdx) = locArr(localeIdx);
    if c.locArr(localeIdx).locale.id == here.id then
      c.myLocArr = c.locArr(localeIdx);
  }
  return c;
}

proc SparseBlockArr.dsiSupportsBulkTransfer() param return false;

proc SparseBlockArr.doiCanBulkTransfer() {
  if dom.stridable then
    for param i in 1..rank do
      if dom.whole.dim(i).stride != 1 then return false;

  // See above note regarding aliased arrays
  if disableAliasedBulkTransfer then
    if _arrAlias != nil then return false;

  return true;
}

// TODO This function needs to be fixed. For now, explicitly returning false
// from dsiSupportsBulkTransfer, so this function should never be compiled
proc SparseBlockArr.doiBulkTransfer(B) {
  halt("SparseBlockArr.doiBulkTransfer not yet implemented");
/*
  if debugSparseBlockDistBulkTransfer then resetCommDiagnostics();
  var sameDomain: bool;
  // We need to do the following on the locale where 'this' was allocated,
  //  but hopefully, most of the time we are initiating the transfer
  //  from the same locale (local on clauses are optimized out).
  on this do sameDomain = dom==B._value.dom;
  // Use zippered iteration to piggyback data movement with the remote
  //  fork.  This avoids remote gets for each access to locArr[i] and
  //  B._value.locArr[i]
  coforall (i, myLocArr, BmyLocArr) in zip(dom.dist.targetLocDom,
                                           locArr,
                                           B._value.locArr) do
    on dom.dist.targetLocales(i) {

    if sameDomain &&
      chpl__useBulkTransfer(myLocArr.myElems, BmyLocArr.myElems) {
      // Take advantage of DefaultRectangular bulk transfer
      if debugSparseBlockDistBulkTransfer then startCommDiagnosticsHere();
      local {
        myLocArr.myElems._value.doiBulkTransfer(BmyLocArr.myElems);
      }
      if debugSparseBlockDistBulkTransfer then stopCommDiagnosticsHere();
    } else {
      if debugSparseBlockDistBulkTransfer then startCommDiagnosticsHere();
      if (rank==1) {
        var lo=dom.locDoms[i].mySparseBlock.low;
        const start=lo;
        //use divCeilPos(i,j) to know the limits
        //but i and j have to be positive.
        for (rid, rlo, size) in ConsecutiveChunks(dom,B._value.dom,i,start) {
          if debugSparseBlockDistBulkTransfer then writeln("Local Locale id=",i,
                                            "; Remote locale id=", rid,
                                            "; size=", size,
                                            "; lo=", lo,
                                            "; rlo=", rlo
                                            );
          // NOTE: This does not work with --heterogeneous, but heterogeneous
          // compilation does not work right now.  This call should be changed
          // once that is fixed.
          var dest = myLocArr.myElems._value.theDataChunk(0);
          const src = B._value.locArr[rid].myElems._value.theDataChunk(0);
          __primitive("chpl_comm_get",
                      __primitive("array_get", dest,
                                  myLocArr.myElems._value.getDataIndex(lo, getChunked=false)),
                      rid,
                      __primitive("array_get", src,
                                  B._value.locArr[rid].myElems._value.getDataIndex(rlo, getChunked=false)),
                      size);
          lo+=size;
        }
      } else {
        var orig=dom.locDoms[i].mySparseBlock.low(dom.rank);
        for coord in dropDims(dom.locDoms[i].mySparseBlock, dom.locDoms[i].mySparseBlock.rank) {
          var lo=if rank==2 then (coord,orig) else ((...coord), orig);
          const start=lo;
          for (rid, rlo, size) in ConsecutiveChunksD(dom,B._value.dom,i,start) {
            if debugSparseBlockDistBulkTransfer then writeln("Local Locale id=",i,
                                        "; Remote locale id=", rid,
                                        "; size=", size,
                                        "; lo=", lo,
                                        "; rlo=", rlo
                                        );
          var dest = myLocArr.myElems._value.theDataChunk(0);
          const src = B._value.locArr[rid].myElems._value.theDataChunk(0);
          __primitive("chpl_comm_get",
                      __primitive("array_get", dest,
                                  myLocArr.myElems._value.getDataIndex(lo, getChunked=false)),
                      dom.dist.targetLocales(rid).id,
                      __primitive("array_get", src,
                                  B._value.locArr[rid].myElems._value.getDataIndex(rlo, getChunked=false)),
                      size);
            lo(rank)+=size;
          }
        }
      }
      if debugSparseBlockDistBulkTransfer then stopCommDiagnosticsHere();
    }
  }
  if debugSparseBlockDistBulkTransfer then writeln("Comms:",getCommDiagnostics());
*/
}

iter ConsecutiveChunks(d1,d2,lid,lo) {
  var elemsToGet = d1.locDoms[lid].mySparseBlock.numIndices;
  const offset   = d2.whole.low - d1.whole.low;
  var rlo=lo+offset;
  var rid  = d2.dist.targetLocsIdx(rlo);
  while (elemsToGet>0) {
    const size = min(d2.numRemoteElems(rlo,rid),elemsToGet):int;
    yield (rid,rlo,size);
    rid +=1;
    rlo += size;
    elemsToGet -= size;
  }
}

iter ConsecutiveChunksD(d1,d2,i,lo) {
  const rank=d1.rank;
  var elemsToGet = d1.locDoms[i].mySparseBlock.dim(rank).length;
  const offset   = d2.whole.low - d1.whole.low;
  var rlo = lo+offset;
  var rid = d2.dist.targetLocsIdx(rlo);
  while (elemsToGet>0) {
    const size = min(d2.numRemoteElems(rlo(rank):int,rid(rank):int),elemsToGet);
    yield (rid,rlo,size);
    rid(rank) +=1;
    rlo(rank) += size;
    elemsToGet -= size;
  }
}

proc SparseBlockDom.numRemoteElems(rlo,rid){
  var blo,bhi:dist.idxType;
  if rid==(dist.targetLocDom.dim(rank).length - 1) then
    bhi=whole.dim(rank).high;
  else
      bhi=dist.boundingBox.dim(rank).low +
        intCeilXDivByY((dist.boundingBox.dim(rank).high - dist.boundingBox.dim(rank).low +1)*(rid+1),
                   dist.targetLocDom.dim(rank).length) - 1;

  return(bhi - rlo + 1);
}

//Brad's utility function. It drops from Domain D the dimensions
//indicated by the subsequent parameters dims.
proc dropDims(D: domain, dims...) {
  var r = D.dims();
  var r2: (D.rank-dims.size)*r(1).type;
  var j = 1;
  for i in 1..D.rank do
    for k in 1..dims.size do
      if dims(k) != i {
        r2(j) = r(i);
        j+=1;
      }
  var DResult = {(...r2)};
  return DResult;
}

