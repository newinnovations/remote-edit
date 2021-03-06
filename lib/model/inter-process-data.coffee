Serializable = require 'serializable'
{CompositeDisposable, Emitter} = require 'atom'

# Defer requiring
Host = null
FtpHost = null
SftpHost = null
LocalFile = null
RemoteFile = null
_ = null
RemoteEditEditor = null

module.exports =
  class InterProcessData
    Serializable.includeInto(this)
    atom.deserializers.add(this)

    constructor: (@hostList) ->
      @emitter = new Emitter
      @disposables = new CompositeDisposable
      @load(@hostList)

    destroy: ->
      @disposables.dispose()
      @emitter.dispose()
      for item in @hostList
        item.destroy()
      @hostList = []

    onDidChange: (callback) ->
      @emitter.on 'did-change', callback

    load: (@hostList = []) ->
      for host in @hostList
        @addSubscriptionToHost(host)

      if atom.config.get 'remote-edit-ni.notifications'
        RemoteEditEditor ?= require '../model/remote-edit-editor'

        @disposables.add atom.workspace.observeTextEditors((editor) =>
          if editor instanceof RemoteEditEditor
            # If a host emits information ('info'), forward this to @messages
            @disposables.add editor.host.onInfo (info) => @notificationHandler(info)
        )

    serializeParams: ->
      {
        hostList: host.serialize() for host in @hostList
      }

    deserializeParams: (params) ->
      tmpArray = []
      if params.hostList
        Host ?= require './host'
        FtpHost ?= require './ftp-host'
        SftpHost ?= require './sftp-host'
        LocalFile ?= require './local-file'
        RemoteFile ?= require './remote-file'
        tmpArray.push(Host.deserialize(host)) for host in params.hostList
      params.hostList = tmpArray
      params

    addSubscriptionToHost: (host) ->
      @disposables.add host.onDidChange =>
        @emitter.emit 'did-change'
      @disposables.add host.onDidDelete (host) =>
        _ ?= require 'underscore-plus'
        host.destroy()
        @hostList = _.reject(@hostList, ((val) -> val == host))
        @emitter.emit 'did-change'

      if atom.config.get 'remote-edit-ni.notifications'
        @disposables.add host.onInfo (info) => @notificationHandler(info)

    # Map notifications to a level
    _levelMap: (strLevel) ->
      level = switch
        when strLevel == "debug" then 10
        when strLevel == "info"  then 20
        when strLevel == "warning" then 30
        when strLevel == "error"  then 40
        when strLevel == "fatal"  then 50
        else 10

    # Handle and filter notifications based on the level configured in settinst
    notificationHandler: (info) ->
      if @_levelMap(info.type) < @_levelMap(atom.config.get('remote-edit-ni.notificationLevel'))
        return
      atom.notifications.add(info.type, info.message)

    addNewHost: (host) ->
      @hostList.push(host)
      @addSubscriptionToHost(host)
      @emitter.emit 'did-change'
