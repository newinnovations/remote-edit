Host = require './host'
RemoteFile = require './remote-file'
LocalFile = require './local-file'
Dialog = require '../view/dialog'

fs = require 'fs-plus'
ssh2 = require 'ssh2'
async = require 'async'
util = require 'util'
filesize = require 'file-size'
moment = require 'moment'
Serializable = require 'serializable'
Path = require 'path'
osenv = require 'osenv'
_ = require 'underscore-plus'
try
  keytar = require 'keytar'
catch err
  console.debug 'Keytar could not be loaded! Passwords will be stored in cleartext to remoteEdit.json!'
  keytar = undefined

module.exports =
  class SftpHost extends Host
    Serializable.includeInto(this)
    atom.deserializers.add(this)

    Host.registerDeserializers(SftpHost)

    connection: undefined
    protocol: "sftp"

    constructor: (@alias = null, @hostname, @directory, @username, @port = "22", @localFiles = [], @useKeyboard = false, @usePassword = false, @useAgent = true, @usePrivateKey = false, @password, @passphrase, @privateKeyPath, @lastOpenDirectory) ->
      # Default to /home/<username> which is the most common case...
      if @directory == ""
        @directory = "/home/#{@username}"

      super( @alias, @hostname, @directory, @username, @port, @localFiles, @usePassword, @lastOpenDirectory)

    getConnectionStringUsingKbdInteractive: ->
      {
        host: @hostname,
        port: @port,
        username: @username,
        tryKeyboard: true
      }



    getConnectionStringUsingAgent: ->
      connectionString =  {
        host: @hostname,
        port: @port,
        username: @username,
      }

      if atom.config.get('remote-edit-ni.agentToUse') != 'Default'
        _.extend(connectionString, {agent: atom.config.get('remote-edit-ni.agentToUse')})
      else if process.platform == "win32"
        _.extend(connectionString, {agent: 'pageant'})
      else
        _.extend(connectionString, {agent: process.env['SSH_AUTH_SOCK']})

      connectionString

    getConnectionStringUsingKey: ->
      if atom.config.get('remote-edit-ni.storePasswordsUsingKeytar') and (keytar?)
        keytarPassphrase = keytar.getPassword(@getServiceNamePassphrase(), @getServiceAccount())
        {host: @hostname, port: @port, username: @username, privateKey: @getPrivateKey(@privateKeyPath), passphrase: keytarPassphrase}
      else
        {host: @hostname, port: @port, username: @username, privateKey: @getPrivateKey(@privateKeyPath), passphrase: @passphrase}


    getConnectionStringUsingPassword: ->
      if atom.config.get('remote-edit-ni.storePasswordsUsingKeytar') and (keytar?)
        keytarPassword = keytar.getPassword(@getServiceNamePassword(), @getServiceAccount())
        {host: @hostname, port: @port, username: @username, password: keytarPassword}
      else
        {host: @hostname, port: @port, username: @username, password: @password}

    getPrivateKey: (path) ->
      if path[0] == "~"
        path = Path.normalize(osenv.home() + path.substring(1, path.length))

      return fs.readFileSync(path, 'ascii', (err, data) ->
        throw err if err?
        return data.trim()
      )

    createRemoteFileFromFile: (path, file) ->
      remoteFile = new RemoteFile(Path.normalize("#{path}/#{file.filename}").split(Path.sep).join('/'), (file.longname[0] == '-'), (file.longname[0] == 'd'), (file.longname[0] == 'l'), filesize(file.attrs.size).human(), parseInt(file.attrs.mode, 10).toString(8).substr(2, 4), moment(file.attrs.mtime * 1000).format("HH:mm:ss DD/MM/YYYY"))
      return remoteFile

    getServiceNamePassword: ->
      "atom.remote-edit-ni.ssh.password"

    getServiceNamePassphrase: ->
      "atom.remote-edit-ni.ssh.passphrase"

    ####################
    # Overridden methods
    getConnectionString: (connectionOptions) ->
      if @useAgent
        connectionOptions = _.extend(@getConnectionStringUsingAgent(), connectionOptions)
      if @usePrivateKey
        connectionOptions = _.extend(@getConnectionStringUsingKey(), connectionOptions)
      if @usePassword
        connectionOptions = _.extend(@getConnectionStringUsingPassword(), connectionOptions)
      if @useKeyboard
        connectionOptions = _.extend(@getConnectionStringUsingKbdInteractive(), connectionOptions)

      return connectionOptions

    close: (callback) ->
      @connection?.end()
      @connection = null
      callback?(null)

    connect: (callback, connectionOptions = {}) ->
      @emitter.emit 'info', {message: "Connecting to sftp://#{@username}@#{@hostname}:#{@port}", type: 'info'}
      async.waterfall([
        (callback) =>
          if @usePrivateKey
            fs.exists(@privateKeyPath, ((exists) =>
              if exists
                callback?(null)
              else
                @emitter.emit 'info', {message: "Private key does not exist!", type: 'error'}
                callback?(new Error("Private key does not exist"))
              )
            )
          else
            callback?(null)
        (callback) =>
          console.debug "Real Host Connect..."
          @connection = new ssh2()
          @connection.on 'error', (err) =>
            @emitter.emit 'info', {message: "Error occured when connecting to sftp://#{@username}@#{@hostname}:#{@port}", type: 'error'}
            @connection?.end()
            callback?(err)
          @connection.on 'ready', =>
            @emitter.emit 'info', {message: "Successfully connected to sftp://#{@username}@#{@hostname}:#{@port}", type: 'success'}
            callback?(null)

          # Here we break MV paradigm... but is the nature of the job...
          @connection.on 'keyboard-interactive', (name, instructions, instructionsLang, prompts, finish) ->
            # console.log('Connection :: keyboard-interactive')
            # console.log(prompts)
            async.waterfall([
              (callback) ->
                passwordDialog = new Dialog({
                  prompt: "Keyboard Interactive Auth",
                  detail: prompts[0].prompt.replace(/(?:\r\n|\r|\n)/g, '<br>')
                })
                passwordDialog.toggle(callback)
            ], (err, result) =>
              if err?
                callback?(err)
              else
                finish([result])
            )

          # Enable keepalive on the connection to keep firewalls and nat happy
          connectionOptions = _.extend({keepaliveInterval: 10000, keepaliveCountMax: 6}, connectionOptions)

          # Go do this...
          @connection.connect(@getConnectionString(connectionOptions))
      ], (err) ->
        callback?(err)
      )

    isConnected: ->
      # @connection? and @connection._sock and @connection._sock.writable and @connection._sshstream and  @connection._sshstream.writable
      if !@connection
        return false
      (@connection._state? and @connection._state isnt 'closed') or (@connection._sshstream?.writable and @connection._sock?.writable)

    getFilesMetadata: (path, callback) ->
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) =>
          # temp store in this so we can close it when we are done...
          @tmp_sftp = sftp
          sftp.readdir(path, callback)
        (files, callback) =>
          # ... and now we are done!
          @tmp_sftp.end()
          async.map(files, ((file, callback) => callback?(null, @createRemoteFileFromFile(path, file))), callback)
        (objects, callback) ->
          objects.push(new RemoteFile((path + "/.."), false, true, false, null, null, null))
          if atom.config.get 'remote-edit-ni.showHiddenFiles'
            callback?(null, objects)
          else
            async.filter(objects, ((item, callback) -> item.isHidden(callback)), ((result) -> callback?(null, result)))
      ], (err, result) =>
        if err?
          @emitter.emit('info', {message: "Error occured when reading remote directory sftp://#{@username}@#{@hostname}:#{@port}:#{path}", type: 'error'} )
          console.error err
          console.error err.code
          callback?(err)
        else
          callback?(err, (result.sort (a, b) -> return if a.name.toLowerCase() >= b.name.toLowerCase() then 1 else -1))

      )

    getFile: (localFile, callback) ->
      @emitter.emit('info', {message: "Getting remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'info'})
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) =>
          sftp.fastGet(localFile.remoteFile.path, localFile.path, (err) => callback(err, sftp))
        (sftp, callback) =>
          sftp.stat(localFile.remoteFile.path, (err, data) => callback(err, sftp, data))
        (sftp, data, callback) =>
          localFile.remoteFile.lastModified = data.mtime
          localFile.remoteFile.lastLoaded = data.mtime
          callback?(null, sftp)
      ], (err, sftp) =>
        @emitter.emit('info', {message: "Error when reading remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'error'}) if err?
        @emitter.emit('info', {message: "Successfully read remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'success'}) if !err?
        sftp?.end()
        callback?(err, localFile)
      )

    updateLastModified: (localFile, callback) ->
      @emitter.emit 'info', {message: "Checking remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'info'}
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) =>
          sftp.stat(localFile.remoteFile.path, (err, data) => callback(err, sftp, data))
        (sftp, data, callback) =>
          localFile.remoteFile.lastModified = data.mtime
          sftp.end()
          callback?()
      ], (err) =>
        if err?
          @emitter.emit('info', {message: "Error occured while checking remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'error'})
          console.error err if err?
        else
          @emitter.emit('info', {message: "Successfully updated mtime sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'success'})

        callback?(err)
      )

    writeFile: (localFile, callback) ->
      @emitter.emit 'info', {message: "Writing remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'info'}
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) ->
          sftp.fastPut(localFile.path, localFile.remoteFile.path, (err) => callback(err, sftp))
        (sftp, callback) =>
          sftp.stat(localFile.remoteFile.path, (err, data) => callback(err, sftp, data))
        (sftp, data, callback) =>
          localFile.remoteFile.lastModified = data.mtime
          localFile.remoteFile.lastLoaded = data.mtime
          sftp.end(callback)
      ], (err) =>
        if err?
          console.error err
          @emitter.emit('info', {message: "Error occured when writing remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}<br/>#{err}", type: 'error'})
        else
          @emitter.emit('info', {message: "Successfully wrote remote file sftp://#{@username}@#{@hostname}:#{@port}#{localFile.remoteFile.path}", type: 'success'})

        callback?(err)
      )

    serializeParams: ->
      tmp = if @password then @password else ""
      {
        @alias
        @hostname
        @directory
        @username
        @port
        localFiles: localFile.serialize() for localFile in @localFiles
        @useKeyboard
        @useAgent
        @usePrivateKey
        @usePassword
        password: new Buffer(tmp).toString("base64")
        @passphrase
        @privateKeyPath
        @lastOpenDirectory
      }

    deserializeParams: (params) ->
      tmpArray = []
      tmpArray.push(LocalFile.deserialize(localFile, host: this)) for localFile in params.localFiles
      params.localFiles = tmpArray
      params.password = if params.password then new Buffer(params.password, "base64").toString("utf8") else ""
      params

    # Create the folder and call the callback. The callback will be called
    # for both error cases (1st arg) and success (2nd arg is the path)
    createFolder: (folderpath, callback) ->
      @emitter.emit 'info', {message: "Creating remote directory at sftp://#{@username}@#{@hostname}:#{@port}#{folderpath}", type: 'info'}
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) ->
          sftp.mkdir(folderpath, callback)
          sftp.end()
          callback?(null, folderpath)
      ], (err) =>
        if err?
          @emitter.emit('info', {message: "Error occured while creating remote directory sftp://#{@username}@#{@hostname}:#{@port}#{folderpath}", type: 'error'})
          console.error err if err?
        else
          @emitter.emit('info', {message: "Successfully created directory sftp://#{@username}@#{@hostname}:#{@port}#{folderpath}", type: 'success'})
        callback?(err)
      )


    createFile: (filepath, callback) ->
      @emitter.emit 'info', {message: "Creating remote file at sftp://#{@username}@#{@hostname}:#{@port}#{filepath}", type: 'info'}
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) =>
          @tmp_sftp = sftp
          sftp.exists(filepath, callback)
        (callback) =>
          @tmp_sftp.writeFile(filepath, "", callback)
        (callback) =>
          @tmp_sftp.end()
          callback?()
        ], (err) =>
            if err?
              if err == true
                @emitter.emit('info', {message: "Fle ftp://#{@username}@#{@hostname}:#{@port}#{filepath} already exists", type: 'error'})
              else
                @emitter.emit('info', {message: "Error occurred while creating remote file ftp://#{@username}@#{@hostname}:#{@port}#{filepath}", type: 'error'})
              console.error err if err?
            else
              @emitter.emit('info', {message: "Successfully wrote remote file ftp://#{@username}@#{@hostname}:#{@port}#{filepath}", type: 'success'})
            callback?(err)
          )


    deleteFolderFile: (deletepath, isFolder, callback) ->
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) =>
          @tmp_sftp = sftp
          if isFolder
            sftp.rmdir(deletepath, callback)
          else
            sftp.unlink(deletepath, callback)
        (callback) =>
          @tmp_sftp.end()
          callback?(null)
        ], (err) =>
          if err?
            @emitter.emit('info', {message: "Error occurred when deleting remote folder/file sftp://#{@username}@#{@hostname}:#{@port}#{deletepath}", type: 'error'})
            console.error err if err?
          else
            @emitter.emit('info', {message: "Successfully deleted remote folder/file sftp://#{@username}@#{@hostname}:#{@port}#{deletepath}", type: 'success'})
          callback?(err)
        )

    renameFolderFile: (path, oldName, newName, isFolder, callback) =>
      if oldName == newName
        @emitter.emit('info', {message: "The new name is same as the old", type: 'error'})
        return

      oldPath = path + "/" + oldName
      newPath = path + "/" + newName

      @moveFolderFile(oldPath, newPath, isFolder, callback)

    moveFolderFile: (oldPath, newPath, isFolder, callback) =>

      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) =>
          @tmp_sftp = sftp
          if isFolder
            sftp.readdir(newPath, callback)
          else
            sftp.exists(newPath, callback)
        ], (err, result) =>
          if (isFolder and result != undefined) or (!isFolder and err==true)
            @emitter.emit('info', {message: "#{if isFolder then 'Folder' else 'File'} already exists", type: 'error'})
            @tmp_sftp.end()
            return

          async.waterfall([
            (callback) =>
              @tmp_sftp.rename(oldPath, newPath, callback)
            (callback) =>
              @tmp_sftp.end()
              callback?()
          ], (err) =>
            if err?
              @emitter.emit('info', {message: "Error occurred when renaming remote folder/file sftp://#{@username}@#{@hostname}:#{@port}#{oldPath}", type: 'error'})
              console.error err if err?
            else
              @emitter.emit('info', {message: "Successfully renamed remote folder/file sftp://#{@username}@#{@hostname}:#{@port}#{oldPath}", type: 'success'})
            callback?(err)
          )
        )

    setPermissions: (path, permissions, callback) =>
      async.waterfall([
        (callback) =>
          @connection.sftp(callback)
        (sftp, callback) =>
          @tmp_sftp = sftp
          sftp.chmod(path, permissions, callback)
        ], (err, result) =>
          if err?
            @emitter.emit('info', {message: "Cannot set permissions to sftp://#{@username}@#{@hostname}:#{@port}#{path}", type: 'error'})
            console.error err if err?

          @tmp_sftp.end()
          callback?(err)
        )
