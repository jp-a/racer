transaction = require './transaction'
pathParser = require './pathParser'
specHelper = require './specHelper'
{merge, hasKeys} = require './util'
argsNormalizer = require './argsNormalizer'

module.exports = RefHelper = (model) ->
  @_model = model
  @_adapter = model._adapter

  @_setup()
  return

ARRAY_OPS = push: 1, unshift: 1, pop: 1, shift: 1, remove: 1, insertAfter: 1, insertBefore: 1, splice: 1, move: 1

# RefHelper contains code that manages an index of refs: the pointer path,
# ref path, key path, and ref type. It uses this index to
# 1. Manage ref dependencies on an adapter update
# 2. Ultimately raise events at the model layer for refs related to a
#    mutated path.
RefHelper:: =

  ## Taxonomy Methods ##

  isPointer: (val) ->
    return !! (val && val.$r)

  isKeyPath: (path, obj) ->
    throw new Error 'Missing obj' unless obj
    found = @_adapter.lookup("$keys.#{path}.$", false, obj: obj).obj
    return found isnt undefined

  isPathPointedTo: (path, obj) ->
    throw 'Missing obj' unless obj
    found = @_adapter.lookup("$refs.#{path}.$", false, obj: obj).obj
    return found isnt undefined

  _setup: ->
    refHelper = @
    adapter = @_adapter

    adapter.__set = adapter.set
    adapter.set = (path, value, ver, options = {}) ->
      out = null
      # Save a record of any references being set
      options.obj ||= @_data

      maybeIndexRefs = (_path, _value) =>
        if refHelper.isPointer _value
          refHelper.$indexRefs _path, _value.$r, _value.$k, _value.$t, ver, options
        if _path == path
          out = @__set path, value, ver, options

        # TODO Move all instances of updateRefsForKey to an event listener?
        # Check to see if setting to a reference's key. If so, update references
        refHelper.updateRefsForKey _path, ver, options

      unless Object == value?.constructor
        maybeIndexRefs path, value
      else
        # TODO Need to traverse an object value, too, for del
        eachNode = (path, value, callback) ->
          callback path, value
          for prop, val of value
            nodePath = "#{path}.#{prop}"
            if Object == val?.constructor
              eachNode nodePath, val, callback
            else
              callback nodePath, val
        eachNode path, value, (nodePath, nodeValue) ->
          maybeIndexRefs nodePath, nodeValue
      return out

    adapter.__del = adapter.del
    adapter.del = (path, ver, options = {}) ->
      options.obj ||= @_data
      out = @__del path, ver, options
      if refHelper.isPathPointedTo path, options.obj
        refHelper.cleanupPointersTo path, options
      return out

    adapter.__remove = adapter.remove
    adapter.remove = (path, start, howMany, ver, options = {}) ->
      options.obj ||= @_data
      #unless refHelper.isArrayRef path, options.obj
      startIndex = refHelper.arrRefIndex start, path, options.obj
      out = @__remove path, startIndex, howMany, ver, options
      # Check to see if setting to a reference's key. If so, update references
      refHelper.updateRefsForKey path, ver, options
      return out
    
    adapter.__move = adapter.move
    adapter.move = (path, from, to, ver, options = {}) ->
      options.obj ||= @_data
      #unless refHelper.isArrayRef path, options.obj
      startIndex = refHelper.arrRefIndex from, path, options.obj
      out = @__move path, startIndex, to, ver, options
      # Check to see if setting to a reference's key. If so, update references
      refHelper.updateRefsForKey path, ver, options
      return out
    
    ['push', 'unshift'].forEach (method) ->
      adapter['__' + method] = adapter[method]
      adapter[method] = ->
        [path, values, ver, options] = argsNormalizer.adapter[method](arguments)
        options.obj ||= @_data
        #unless refHelper.isArrayRef path, options.obj
        out = @['__' + method] path, values..., ver, options
        # Check to see if setting to a reference's key. If so, update references
        refHelper.updateRefsForKey path, ver, options
        return out

    ['pop', 'shift'].forEach (method) ->
      adapter['__' + method] = adapter[method]
      adapter[method] = (path, ver, options = {}) ->
        options.obj ||= @_data
        #unless refHelper.isArrayRef path, options.obj
        out = @['__' + method] path, ver, options
        # Check to see if setting to a reference's key. If so, update references
        refHelper.updateRefsForKey path, ver, options
        return out

    ['insertAfter', 'insertBefore'].forEach (method) ->
      adapter['__' + method] = adapter[method]
      adapter[method] = (path, pos, value, ver, options = {}) ->
        options.obj ||= @_data
        #unless refHelper.isArrayRef path, options.obj
        index = refHelper.arrRefIndex pos, path, options.obj
        out = @['__' + method] path, index, value, ver, options
        # Check to see if setting to a reference's key. If so, update references
        refHelper.updateRefsForKey path, ver, options
        return out

    adapter.__splice = adapter.splice
    adapter.splice = ->
      [path, start, removeCount, newMembers, ver, options] = argsNormalizer.adapter.splice(arguments)
      options.obj ||= @_data
      #unless refHelper.isArrayRef path, options.obj
      startIndex = refHelper.arrRefIndex start, path, options.obj
      out = @__splice path, startIndex, removeCount, newMembers..., ver, options
      # Check to see if setting to a reference's key. If so, update references
      refHelper.updateRefsForKey path, ver, options
      return out

  # This function returns the index of an array ref member, given a member
  # id or index (as start) of an array ref (represented by path) in the
  # context of the object, obj.
  arrRefIndex: (start, path, obj) ->
    if 'number' == typeof start
      # index api
      return start

    arr = @_adapter.lookup(path, true, obj: obj).obj
    if @isArrayRef path, obj
      # id api
      startIndex = arr.length
      for mem, i in arr
        # TODO parseInt will cause bugs later on when we use string uuids for id
        return startIndex = i if mem.id == start.id || parseInt(mem.id, 10) == parseInt(start.id, 10)

    startIndex = arr.indexOf start.id
    return startIndex if startIndex != -1
    startIndex = arr.indexOf parseInt(start.id, 10)
    return startIndex if startIndex != -1
    return arr.indexOf start.id.toString()


  ## Pointer Builders ##

  # Used via delegation from Model::ref
  ref: (ref, key) ->
    if key? then $r: ref, $k: key else $r: ref

  # Used via delegation from Model::arrayRef
  arrayRef: (ref, key) ->
    $r: ref, $k: key, $t: 'array'
  
  # If a key is present, merges
  #     TODO key is redundant here
  #     { <path>: [<ref>, <key>, <type>] }
  # into
  #     "$keys":
  #       "#{key}":
  #         $:
  #
  # and merges
  #     { <path>: [<ref>, <key>, <type>] }
  # into
  #     $refs:
  #       <ref>.<lookup(key)>: 
  #         $:
  #
  # If key is not present, merges
  #     <path>: [<ref>, undefined]
  # into
  #     $refs:
  #       <ref>: 
  #         $:
  #
  # $refs is a kind of index that allows us to lookup
  # which references pointed to the path, `ref`, or to
  # a path that `ref` is a descendant of.
  #
  # [*] The only purpose of these data structures appears to be for
  # mutator events also emitting to references that pointed at the original
  # mutated path
  #
  # @param {String} path that is de-referenced to a true path represented by
  #                 lookup(ref + '.' + lookup(key))
  # @param {String} ref is what would be the `value` of $r: `value`.
  #                 It's what we are pointing to
  # @param {String} key is a path that points to a pathB or array of paths
  #                 as another lookup chain on the dereferenced `ref`
  # @param {String} type can be undefined or 'array'
  # @param {Number} ver
  # @param {Object} options
  $indexRefs: (path, ref, key, type, ver, options) ->
    adapter = @_adapter
    refHelper = @
    oldRefOptions = merge {dontFollowLastRef: true}, options
    oldRefObj = adapter.lookup(path, false, oldRefOptions).obj
    if key
      entry = [ref, key]
      entry.push type if type
#      # We denormalize the path here. Why? e.g.,
#      # If path = _group.todoIds, but lookup(path) does not exist at this point,
#      # then the dereferenced path resolves to undefined, which is flawed.
#      path = @denormalizePath path, options.obj
      adapter.lookup("$keys.#{key}.$", true, options).obj[path] = entry
      keyVal = adapter.lookup(key, false, options).obj
      # keyVal is only valid if it can be a valid path segment
      return if type is undefined and keyVal is undefined
      if type == 'array'
        keyOptions = merge { array: true }, options
        keyVal = adapter.lookup(key, true, keyOptions).obj
        refsKeys = keyVal.map (keyValMem) -> ref + '.' + keyValMem
        @_removeOld$refs oldRefObj, path, ver, options
        return refsKeys.forEach (refsKey) ->
          refHelper._update$refs refsKey, path, ref, key, type, options
      refsKey = ref + '.' + keyVal
    else
      if oldRefObj && oldKey = oldRefObj.$k
        refs = adapter.lookup("$keys.#{oldKey}.$", false, options).obj
        if refs && refs[path]
          delete refs[path]
          adapter.del "$keys.#{oldKey}", ver, options unless hasKeys refs, ignore: specHelper.reserved
      refsKey = ref
    @_removeOld$refs oldRefObj, path, ver, options
    @_update$refs refsKey, path, ref, key, type, options

  # Private helper function for $indexRefs
  _removeOld$refs: (oldRefObj, path, ver, options) ->
    if oldRefObj && oldRef = oldRefObj.$r
      if oldKey = oldRefObj.$k
        oldKeyVal = @_adapter.lookup(oldKey, false, options).obj
      if oldKey && (oldRefObj.$t == 'array')
        # If this key was used in an array ref: {$r: path, $k: [...]}
        refHelper = @
        oldKeyVal.forEach (oldKeyMem) ->
          refHelper._removeFrom$refs oldRef, oldKeyMem, path, ver, options
        @_removeFrom$refs oldRef, undefined, path, ver, options
      else
        @_removeFrom$refs oldRef, oldKeyVal, path, ver, options

  # Private helper function for $indexRefs
  _removeFrom$refs: (ref, key, path, ver, options) ->
    refWithKey = ref + '.' + key if key
    refEntries = @_adapter.lookup("$refs.#{refWithKey}.$", false, options).obj
    return unless refEntries
    delete refEntries[path]
    unless hasKeys(refEntries, ignore: specHelper.reserved)
      @_adapter.del "$refs.#{ref}", ver, options
    
  # Private helper function for $indexRefs
  _update$refs: (refsKey, path, ref, key, type, options) ->
    entry = [ref, key]
    entry.push type if type
    # TODO DRY - Above 2 lines are duplicated below
    out = @_adapter.lookup("$refs.#{refsKey}.$", true, options)
    out.obj[path] = entry

  # If path is a reference's key ($k), then update all entries in the
  # $refs index that use this key. i.e., update the following
  #
  #     $refs: <ref>.<keyVal>: $: <path>: [<ref>, <key>]
  #                         *
  #                         |
  #                       Update <keyVal> = <lookup(key)>
  updateRefsForKey: (path, ver, options) ->
    if refs = @_adapter.lookup("$keys.#{path}.$", false, options).obj
      @_eachValidRef refs, options.obj, (path, ref, key, type) =>
        @$indexRefs path, ref, key, type, ver, options
    @eachValidRefPointingTo path, options.obj, (pointingPath, targetPathRemainder, ref, key, type) =>
      @updateRefsForKey pointingPath + '.' + targetPathRemainder, ver, options

  ## Iterators ##
  _eachValidRef: (refs, obj = @_adapter._data, callback) ->
    fastLookup = pathParser.fastLookup
    for path, [ref, key, type] of refs

      # Ignore the _proto key that we use to identify Object.created objs
      # TODO Better encapsulate this
      continue if path == '_proto'

      # Check to see if the reference is still the same
      o = fastLookup path, obj
      o = @_adapter.lookup(path, false, obj: obj, dontFollowLastRef: true).obj
      if o && o.$r == ref && `o.$k == key`
        # test `o.$k == key` not via ===
        # because key is converted to null when JSON.stringified before being sent here via socket.io
        callback path, ref, key, type
      else
        delete refs[path]
        # Lazy cleanup

  # Passes back a set of references when we find references to path.
  # Also passes back a set of references and a path remainder
  # every time we find references to any of path's ancestor paths
  # such that `ancestor_path + path_remainder == path`
  _eachRefSetPointingTo: (path, refs, fn) ->
    i = 0
    refPos = refs
    props = path.split '.'
    while prop = props[i++]
      return unless refPos = refPos[prop]
      if refSet = refPos.$
        fn refSet, props.slice(i).join('.'), prop

  eachValidRefPointingTo: (targetPath, obj, fn) ->
    self = this
    adapter = self._adapter
    return unless refs = adapter.lookup('$refs', false, obj: obj).obj
    self._eachRefSetPointingTo targetPath, refs, (refSet, targetPathRemainder, possibleIndex) ->
      # refSet has signature: { "#{pointingPath}$#{ref}": [pointingPath, ref], ... }
      self._eachValidRef refSet, obj, (pointingPath, ref, key, type) ->
        if type == 'array'
          targetPathRemainder = possibleIndex + '.' + targetPathRemainder
        fn pointingPath, targetPathRemainder, ref, key, type

  eachArrayRefKeyedBy: (path, obj, fn) ->
    return unless refs = @_adapter.lookup("$keys", false, obj: obj).obj
    refSet = (path + '.$').split('.').reduce (refSet, prop) ->
      refSet && refSet[prop]
    , refs
    return unless refSet
    for path, [ref, key, type] of refSet
      fn path, ref, key if type == 'array'

  # Notify any path that referenced the `path`. And
  # notify any path that referenced the path that referenced the path.
  # And notify ... etc...
  notifyPointersTo: (targetPath, obj, method, args, ignoreRoots = []) ->
    # Takes care of regular refs
    @eachValidRefPointingTo targetPath, obj, (pointingPath, targetPathRemainder, ref, key, type) =>
      unless type == 'array'
        return if @_alreadySeen pointingPath, ref, ignoreRoots
        pointingPath += '.' + targetPathRemainder if targetPathRemainder
      else if targetPathRemainder
        # Take care of target paths which include an array ref pointer path
        # as a substring of the target path.
        [id, rest...] = targetPathRemainder.split '.'
        index = @_toIndex key, id, obj
        unless index == -1
          pointingPath += '.' + index
          pointingPath += '.' + rest.join('.') if rest.length
      @_model.emit method, [pointingPath, args...]

    # Takes care of array refs
    @eachArrayRefKeyedBy targetPath, obj, (pointingPath, ref, key) =>
      # return if @_alreadySeen pointingPath, ref, ignoreRoots
      [firstArgs, arrayMemberArgs] = @splitArrayArgs method, args
      if arrayMemberArgs
        ns = @_adapter.lookup(ref, false, obj: obj).obj
        arrayMemberArgs = arrayMemberArgs.map (arg) ->
          ns[arg] || ns[parseInt arg, 10]
          # { $r: ref, $k: arg }
      args = firstArgs.concat arrayMemberArgs
      @_model.emit method, [pointingPath, args...]

  _toIndex: (arrayRefKey, id, obj) ->
    keyArr = @_adapter.lookup(arrayRefKey, false, array: true, obj: obj).obj
    index = keyArr.indexOf id
    if index == -1
      # Handle numbers just in case
      return keyArr.indexOf parseInt(id, 10)
    return index

  # For avoiding infinite event emission
  _alreadySeen: (pointingPath, ref, ignoreRoots) ->
    # TODO More proper way to detect cycles? Or is this sufficient?
    alreadySeen = ignoreRoots.some (root) ->
      root == pointingPath.substr(0, root.length)
    return true if alreadySeen
    ignoreRoots.push ref
    return false

  cleanupPointersTo: (path, options) ->
    adapter = @_adapter
    refs = adapter.lookup("$refs.#{path}.$", false, options).obj
    return if refs is undefined
    model = @_model
    for pointingPath, [ref, key] of refs
      keyVal = key && adapter.lookup(key, false, options).obj
      if keyVal && Array.isArray keyVal
        keyMem = path.substr(ref.length + 1, pointingPath.length)
        # TODO Use model.remove here instead?
        adapter.remove key, keyVal.indexOf(keyMem), 1, null, options
#      else
#        # TODO Use model.del here instead?
#        adapter.del pointingPath, null, options
  
  # Used to normalize a transaction to its de-referenced parts before
  # adding it to the model's txnQueue
  dereferenceTxn: (txn, obj) ->
    method = transaction.method txn
    args = transaction.args txn
    path = transaction.path txn
    if ARRAY_OPS[method]
      sliceFrom = switch method
        when 'push', 'unshift' then 1
        when 'pop', 'shift', 'insertAfter', 'insertBefore' then 2
        when 'remove', 'move', 'splice' then 3
        else throw new Error 'Unimplemented for method ' + method

      if { $r, $k } = @isArrayRef path, obj
        # TODO Instead of invalidating, roll back the spec model cache by 1 txn
        @_model._cache.invalidateSpecModelCache()
        # TODO Add test to make sure that we assign the de-referenced $k to path
        args[0] = path = $k
        oldPushArgs = args.slice sliceFrom
        newPushArgs = oldPushArgs.map (refObjToAdd) ->
          if refObjToAdd.$r is undefined
            throw new Error 'Trying to push a non-ref onto an array ref'
          if $r != refObjToAdd.$r
            throw new Error "Trying to push elements of type #{refObjToAdd.$r} onto path #{path} that is an array ref of type #{$r}"
          return refObjToAdd.$k
        args.splice sliceFrom, oldPushArgs.length, newPushArgs...
      else
        # Update the transaction's path with a dereferenced path if not undefined.
        {obj, path, remainingProps} = @_adapter.lookup path, false, obj: obj
        if obj is undefined && remainingProps?.length
          args[0] = [path].concat(remainingProps).join('.')
        else
          args[0] = path
      return txn

    # Update the transaction's path with a dereferenced path.
    {obj, path, remainingProps} = @_adapter.lookup path, false, obj: obj
    if obj is undefined && remainingProps?.length
      args[0] = [path].concat(remainingProps).join('.')
    else
      args[0] = path
    return txn

  # isArrayRef
  # @param {String} path that we want to determine is a pointer or not
  # @param {Object} data is the speculative or true model data
  isArrayRef: (path, data) ->
    options = obj: data, dontFollowLastRef: true
    refObj = @_adapter.lookup(path, false, options).obj
    return false if refObj is undefined
    {$r, $k, $t} = refObj
    $k = @dereferencedPath $k, data if $k
    return if $t == 'array' then { $r, $k } else false
  
  splitArrayArgs: (method, args) ->
    switch method
      when 'push' then return [[], args]
      when 'insertAfter', 'insertBefore'
        return [[args[0]], args.slice(1)]
      when 'splice'
        return [args[0..1], args.slice(2)]
      else
        return [args, []]

  isRefObj: (obj) -> '$r' of obj

  dereferencedPath: (path, data) ->
    meta = @_adapter.lookup path, false, obj: data, returnMeta: true
    return meta.path

  denormalizePath: (path, data) ->
    {path, obj, remainingProps} = @_adapter.lookup path, false, obj: data
    return path if obj || ! (remainingProps?.length)
    return [path].concat(remainingProps).join('.')
