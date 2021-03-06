racer = require 'racer'
todoHtml = require('./shared').todoHtml

# racer.ready returns a callback function for a DOM ready event. Its callback
# will only be called once both the model data are loaded and the event that
# it is passed to occurs.
# Alternatively, racer.onload can be set to a function that only waits for
# the model data to be loaded.
# Calling $() with a function is equivalent to $(document).ready() in jQuery
$ racer.ready ->
  model = racer.model
  newTodo = $ '#new-todo'
  todoList = $ '#todos'
  content = $ '#content'
  overlay = $ '#overlay'
  listPath = '_group.todoList'


  ## Update the DOM when the model changes ##

  model.on 'connectionStatus', (connected, canConnect) ->
    overlay.html(if connected
      ''
    else if canConnect
      '<p id=info>Offline<span id=reconnect> &ndash; <a href=# onclick="return todos.connect()">Reconnect</a></span>'
    else
      '<p id=info>Unable to reconnect &ndash; <a href=javascript:window.location.reload()>Reload</a>'
    )

  model.on 'push', listPath, (value) ->
    todoList.append todoHtml(value)

  model.on 'insertBefore', listPath, (index, value) ->
    todoList.children().eq(index).before todoHtml(value)

  model.on 'set', '_group.todos.*.completed', (id, value) ->
    $("##{id}").toggleClass 'completed', value
    $("#check#{id}").prop 'checked', value

  model.on 'remove', listPath, ({id}) ->
    $("##{id}").remove()

  model.on 'move', listPath, ({id, index}, to) ->
    target = todoList.children().get to
    # Don't move if the item is already in the right position
    return if id.toString() is target.id
    if index > to && to != -1
      $("##{id}").insertBefore target
    else
      $("##{id}").insertAfter target

  model.on 'set', '_group.todos.*.text', (id, value) ->
    el = $ "#text#{id}"
    return if el.is ':focus'
    el.html value


  ## Update the model in response to DOM events ##

  window.todos =
  
    connect: ->
      reconnect = document.getElementById 'reconnect'
      reconnect.style.display = 'none'
      # Hide the reconnect link for a second so it looks like something is going on
      setTimeout (-> reconnect.style.display = 'inline'), 1000
      model.socket.socket.connect()
      return false

    addTodo: ->
      # Don't add a blank todo
      return unless text = newTodo.val()
      newTodo.val ''
      # Insert the new todo before the first completed item in the list
      for todo, i in list = model.get listPath
        break if todo.completed
      todo = 
        id: model.incr '_group.nextId'
        completed: false
        text: text
      if i == list.length
        # Append to the end if there are no completed items
        model.push listPath, todo
      else
        model.insertBefore listPath, i, todo

    check: (checkbox, id) ->
      model.set "_group.todos.#{id}.completed", checkbox.checked
      # Move the item to the bottom if it was checked off
      model.move listPath, {id}, -1 if checkbox.checked

    del: (id) ->
      model.remove listPath, id: id

  todoList.sortable
    handle: '.handle'
    axis: 'y'
    containment: '#dragbox'
    update: (e, ui) ->
      item = ui.item[0]
      to = todoList.children().index(item)
      model.move listPath, {id: item.id}, to

  # Watch for changes to the contenteditable fields
  lastHtml = ''
  checkChanged = (e) ->
    html = content.html()
    return if html == lastHtml
    lastHtml = html
    target = e.target
    return unless id = target.getAttribute 'data-id'
    text = target.innerHTML
    model.set "_group.todos.#{id}.text", text
  # Paste and dragover events are fired before the HTML is actually updated
  checkChangedDelayed = (e) ->
    setTimeout checkChanged, 10, e

  # Shortcuts
  # Bold: Ctrl/Cmd + B
  # Italic: Ctrl/Cmd + I
  # Clear formatting: Ctrl/Cmd + Space -or- Ctrl/Cmd + \
  checkShortcuts = (e) ->
    return unless e.metaKey || e.ctrlKey
    code = e.which
    return unless command = `
      code === 66 ? 'bold' :
      code === 73 ? 'italic' :
      code === 32 ? 'removeFormat' :
      code === 220 ? 'removeFormat' : null`
    document.execCommand command, false, null
    e.preventDefault() if e.preventDefault
    return false

  content
    .keydown(checkShortcuts)
    .keydown(checkChanged)
    .keyup(checkChanged)
    .bind('paste', checkChangedDelayed)
    .bind('dragover', checkChangedDelayed)

  # Tell Firefox to use elements for styles instead of CSS
  # See: https://developer.mozilla.org/en/Rich-Text_Editing_in_Mozilla
  document.execCommand 'useCSS', false, true
  document.execCommand 'styleWithCSS', false, false

racer.init @init
delete @init

