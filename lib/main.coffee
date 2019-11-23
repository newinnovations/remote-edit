_ = require 'underscore-plus'
# Import needed to register deserializer
RemoteEditEditor = require './model/remote-edit-editor'
os = require 'os'


# Deferred requirements
OpenFilesView = null
HostView = null
HostsView = null
FilesView = null
Host = null
SftpHost = null
FtpHost = null
LocalFile = null
url = null
InterProcessDataWatcher = null
fs = null

module.exports =
  config:
    showHiddenFiles:
      title: 'Show hidden files'
      type: 'boolean'
      default: false
    uploadOptions:
      type: 'object'
      properties:
        uploadOnSave:
          title: 'Upload on save'
          description: 'When enabled, remote files will be automatically uploaded when saved'
          type: 'boolean'
          default: true
        closeOnUpload:
          title: 'Close connection after every upload'
          description: """When enabled, it will not persist upload connection.
                        Only effective when "Upload on save" is checked. Enabling
                        this will minimize the number of connections to the server
                        but will introduce the overhead of reconnecting on every save"""
          type: 'boolean'
          default: false
        fileModifiedCheckInterval:
          title: '[EXPERIMENTAL] Check remote file for changes and auto-refresh'
          description: """Periodically check all the open files (using stat and
                       mtime). When a change is detected, if the local file is
                       not modified, it will automatically reload the tab. If
                       both local and remote files are changed, then a panel will
                       be displayed for the user to choose action (reload or ignore)
                       A value of 0 disables checking (value in seconds).
                       NOTE: It applies ONLY to newly opened tabs
                       """
          type: 'integer'
          default: 0
    notifications:
      title: 'Display notifications'
      type: 'boolean'
      default: true
    notificationLevel:
      title: 'Notification Level'
      type: 'string'
      default: 'error'
      enum: ['fatal', 'error', 'warning', 'info', 'debug']
    sshPrivateKeyPath:
      title: 'Path to private SSH key'
      type: 'string'
      default:  os.homedir() + '/.ssh/id_rsa'
    defaultSerializePath:
      title: 'Default path to serialize remoteEdit data'
      type: 'string'
      default: os.homedir() + '/.atom/remoteEdit.json'
    agentToUse:
      title: 'SSH agent'
      description: 'Overrides default SSH agent. See ssh2 docs for more info.'
      type: 'string'
      default: 'Default'
    foldersOnTop:
      title: 'Show folders on top'
      type: 'boolean'
      default: false
    followLinks:
      title: 'Follow symbolic links'
      description: 'If set to true, symbolic links are treated as directories'
      type: 'boolean'
      default: true
    clearFileList:
      title: 'Clear file list'
      description: 'When enabled, the open files list will be cleared on initialization'
      type: 'boolean'
      default: true
    rememberLastOpenDirectory:
      title: 'Remember last open directory'
      description: 'When enabled, browsing a host will return you to the last directory you entered'
      type: 'boolean'
      default: false
    storePasswordsUsingKeytar:
      title: 'Store passwords using node-keytar'
      description: 'When enabled, passwords and passphrases will be stored in system\'s keychain'
      type: 'boolean'
      default: false
    filterHostsUsing:
      type: 'object'
      properties:
        hostname:
          type: 'boolean'
          default: true
        alias:
          type: 'boolean'
          default: false
        username:
          type: 'boolean'
          default: false
        port:
          type: 'boolean'
          default: false
    showOpenedTree:
      title: 'Show Opened Files Tree'
      type: 'boolean'
      default: true


  activate: (state) ->
    @setupOpeners()
    @initializeIpdwIfNecessary()

    atom.commands.add('atom-workspace', 'remote-edit:show-open-files', => @showOpenFiles())
    atom.commands.add('atom-workspace', 'remote-edit:browse', => @browse())
    # Browse more is a slight variation of remote-edit:reveal-in-browser
    # The only difference is that if the current tab is not RemoteEditEditor
    # it will open hosts-view
    atom.commands.add('atom-workspace', 'remote-edit:browse-more', => @browseMore())
    atom.commands.add('atom-workspace', 'remote-edit:new-sftp-host', => @newHost("sftp"))
    atom.commands.add('atom-workspace', 'remote-edit:new-ftp-host', => @newHost("ftp"))
    atom.commands.add('atom-workspace', 'remote-edit:toggle-files-view', => @createFilesView().toggle())
    atom.commands.add('atom-workspace', 'remote-edit:reload-current-folder', => @createFilesView().reloadFolder())

  deactivate: ->
    @ipdw?.destroy()

  newHost: (type="sftp") ->
    HostView ?= require './view/host-view'
    if type == "sftp"
      SftpHost ?= require './model/sftp-host'
      host = new SftpHost()
    else if type == "ftp"
      FtpHost ?= require './model/ftp-host'
      host = new FtpHost()

    view = new HostView(host, @getOrCreateIpdw())
    view.toggle()

  browse: ->
    HostsView ?= require './view/hosts-view'
    view = new HostsView(@getOrCreateIpdw())
    view.toggle()

  browseMore: ->
    editor = atom.workspace.getActiveTextEditor()
    if editor instanceof RemoteEditEditor
      @createFilesView().revealCurrentFile()
    else
      @browse()

  showOpenFiles: ->
    OpenFilesView ?= require './view/open-files-view'
    showOpenFilesView = new OpenFilesView(@getOrCreateIpdw())
    showOpenFilesView.toggle()

  createFilesView: ->
    unless @filesView?
      FilesView = require './view/files-view'
      @filesView = new FilesView(@state)
    @filesView

  initializeIpdwIfNecessary: ->
    if atom.config.get 'remote-edit-ni.notifications'
      stop = false
      for editor in atom.workspace.getTextEditors() when !stop
        if editor instanceof RemoteEditEditor
          @getOrCreateIpdw()
          stop = true

  getOrCreateIpdw: ->
    if @ipdw is undefined
      InterProcessDataWatcher ?= require './model/inter-process-data-watcher'
      fs = require 'fs-plus'
      @ipdw = new InterProcessDataWatcher(fs.absolute(atom.config.get('remote-edit-ni.defaultSerializePath')))
    else
      @ipdw

  setupOpeners: ->
    atom.workspace.addOpener (uriToOpen) ->
      url ?= require 'url'
      try
        {protocol, host, query} = url.parse(uriToOpen, true)
      catch error
        return
      return unless protocol is 'remote-edit:'

      if host is 'localfile'
        Host ?= require './model/host'
        FtpHost ?= require './model/ftp-host'
        SftpHost ?= require './model/sftp-host'
        LocalFile ?= require './model/local-file'
        localFile = LocalFile.deserialize(JSON.parse(decodeURIComponent(query.localFile)))
        host = Host.deserialize(JSON.parse(decodeURIComponent(query.host)))

        atom.project.bufferForPath(localFile.path).then (buffer) ->
          params = {buffer: buffer, registerEditor: true, host: host, localFile: localFile, autoHeight: false}
          # copied from workspace.buildTextEditor
          ws = atom.workspace
          params = _.extend({
            config: ws.config, notificationManager: ws.notificationManager, packageManager: ws.packageManager, clipboard: ws.clipboard, viewRegistry: ws.viewRegistry,
            grammarRegistry: ws.grammarRegistry, project: ws.project, assert: ws.assert, applicationDelegate: ws.applicationDelegate, autoHeight: false
          }, params)
          editor = new RemoteEditEditor(params)
