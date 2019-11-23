/*
 * TODO:
 *   DS102: Remove unnecessary code created because of implicit returns
 *   DS206: Consider reworking classes to avoid initClass
 *   DS207: Consider shorter variations of null checks
 */
let Editor, RemoteEditEditor;
const path = require('path');


let resourcePath = atom.config.resourcePath;
if (!resourcePath) {
	resourcePath = atom.getLoadSettings().resourcePath;
}

try {
	Editor = require(path.resolve(resourcePath, 'src', 'editor'));
} catch (e) {
}
// Catch error
const TextEditor = Editor != null ? Editor : require(path.resolve(resourcePath, 'src', 'text-editor'));

// Defer requiring
let Host = null;
let FtpHost = null;
let SftpHost = null;
let LocalFile = null;
let async = null;
let Dialog = null;
let _ = null;

const SERIALIZATION_VERSION = 1

module.exports =
	(RemoteEditEditor = (function() {
		RemoteEditEditor = class RemoteEditEditor extends TextEditor {
			static initClass() {
				atom.deserializers.add(this);
			}

			constructor(params) {
				if (params == null) {
					params = {};
				}

				super(params);

				// Store our original parameters. These are used later on to
				// initialize a cloned RemoteEditEditor in `copy()`
				this.remoteEditParams = params;

				if (params.host) {
					this.host = params.host;
				} else if (params.reHost) {
					Host = require('../model/host');
					FtpHost = require('../model/ftp-host');
					SftpHost = require('../model/sftp-host');
					this.host = Host.deserialize(params.reHost);
				}  else {
					throw "No host in RemoteEditEditor constructor";
				}
				if (params.localFile) {
					this.localFile = params.localFile;
				} else if (params.reLocalFile) {
					LocalFile = require('../model/local-file');
					this.localFile = LocalFile.deserialize(params.reLocalFile);
				} else {
					throw "No localFile in RemoteEditEditor constructor";
				}

				// This is here for consistency since sometimes the localFile.host
				// is not set. Prefer using this.host instead
				if (!this.localFile.host && params.host) {
					this.localFile.host = params.host
				}

				this.startRefresh()
			}

			/**
			 * Init a banner (div) that can be attached on the top of the
			 * atom-text-editor. This is a bit of hack but we need a way to
			 * display messages per-file
			 */
			_initBanner() {
				this.banner = document.createElement("div");
				this.banner.className = "text-editor-banner";
				this.banner.style.width = "100%";
				this.banner.style.padding = "10px";
				this.banner.style.zIndex = 10;
				this.banner.style.position = "absolute";
				this.banner.style.top = "auto";
				this.banner.style.left = "auto";
				this.banner.style.bottom = "auto";
				this.banner.style.right = "auto";
				let self = this;
				this.editorObserver = new MutationObserver(
					(mutationsList, observer) => {
						for(let mutation of mutationsList) {
							if (mutation.type != 'attributes')
								continue;
							if (mutation.attributeName != "style")
								continue;

							// Sync display!
							let editor = self.getElement()
							if (!editor || !self.banner)
								continue;
							self.banner.style.display = editor.style.display;
							let height = self.banner.offsetHeight;
							editor.firstChild.style.top = height + "px";
						}
					}
				);

			}

			/**
			 * Reload the buffer from the remote file.
			 */
			reload(final_callback) {
				let self = this;

				async.waterfall([
				  (callback) => {
					  self.host.getFile(self.localFile, callback);
				  },
				  (localFile, callback) => {
					  self.getBuffer().reload();
					  final_callback();
				  }
				])
			}

			hideBanner() {
				this.banner.style.display = "none";
				while (this.banner.firstChild) {
				    this.banner.removeChild(this.banner.firstChild);
				}
				this.getElement().firstChild.style.top = 0;
				this.editorObserver.disconnect();
			}

			/**
			 * Given a DOM element, attach it to this.banner and display it
			 */
			displayBanner(element) {
				let editorElement = this.getElement();
				let parentNode = editorElement.parentNode;
				if (!this.banner)
					this._initBanner();
					// Attach observer so we know when the banner should hide
					this.editorObserver.observe(editorElement, {attributes: true});

				// If on other tab, this should be hidden
				this.banner.style.display = editorElement.style.display;
				this.banner.appendChild(element);
				parentNode.insertBefore(this.banner, parentNode.firstChild);
				let height = this.banner.offsetHeight;
				editorElement.firstChild.style.top = height + "px";
			}

			/**
			 * Start checking the remote file periodically. If the interval is
			 * less or eq to 0 then checking is aborted
			 */
			startRefresh() {
				let interval = atom.config.get(
					'remote-edit-ni.uploadOptions.fileModifiedCheckInterval'
				);
				if (interval <= 0)
					return;

				interval = interval * 1000;
				let self = this;
				this.checkTimer = setInterval(() => {self.checkRemote()}, interval);
			}

			displayFileModifiedBanner() {
				let self = this;
				let top = document.createElement("div");
				let msg = document.createElement("div");
				let actions = document.createElement("div");
				top.appendChild(msg);
				top.appendChild(actions);
				msg.appendChild(document.createTextNode(
					"Both the local and the remote file has been modified. " +
					"Choose action (with reload you will lose the local changes):"
				));

				let ignore = document.createElement("button");
				ignore.className = "inline-block btn";
				ignore.innerHTML = "Ignore";
				ignore.onclick = function() {
					self.startRefresh();
					self.hideBanner();
				}

				let reload = document.createElement("button");
				reload.className = "inline-block btn";
				reload.innerHTML = "Reload";
				reload.onclick = function() {
				  async.waterfall([
					(callback) => {
						self.reload(callback);
					},
					(callback) => {
						self.startRefresh();
					  	self.hideBanner();
						return;
					}
				  ])
				}

				actions.appendChild(ignore);
				actions.appendChild(reload);

				this.displayBanner(top);
			}

			checkRemote() {
				if (async == null) {
					async = require('async');
				}

				let self = this
				async.waterfall([
					callback => {
						if (!this.host.isConnected()) {
							this.host.connect(callback, {});
						} else {
							callback();
						}
					},
					callback => {
						this.host.updateLastModified(this.localFile, callback);
					},
					callback => {
						if (!this.localFile.remoteFile.needsRefresh()) {
							return callback(null);
						}
						clearInterval(this.checkTimer);
						this.checkTimer = null

						if (!this.isModified()) {
							this.reload(() => {
  		  					  self.startRefresh();
							});
							return;
						}

						this.displayFileModifiedBanner();

					}
				])

			}

			copy() {
				return new RemoteEditEditor(this.remoteEditParams)
			}

			destroy () {
				// Call parent to remove the view
				TextEditor.prototype.destroy.call(this)
				// Now do our clean-up
				if (this.host)
					this.host.close()
				clearInterval(this.checkTimer)
			}

			getIconName() {
				return "globe";
			}

			getTitle() {
				let sessionPath;
				if (this.localFile != null) {
					return this.localFile.name;
				} else if ((sessionPath = this.getPath())) {
					return path.basename(sessionPath);
				} else {
					return "undefined";
				}
			}

			getLongTitle() {
				let directory, i, relativePath;
				if (Host == null) {
					Host = require('./host');
				}
				if (FtpHost == null) {
					FtpHost = require('./ftp-host');
				}
				if (SftpHost == null) {
					SftpHost = require('./sftp-host');
				}

				if (i = this.localFile.remoteFile.path.indexOf(this.host.directory) > -1) {
					relativePath = this.localFile.remoteFile.path.slice((i + this.host.directory.length));
				}

				const fileName = this.getTitle();
				if (this.host instanceof SftpHost && (this.host != null) && (this.localFile != null)) {
					directory = (relativePath != null) ? relativePath : `sftp://${this.host.username}@${this.host.hostname}:${this.host.port}${this.localFile.remoteFile.path}`;
				} else if (this.host instanceof FtpHost && (this.host != null) && (this.localFile != null)) {
					directory = (relativePath != null) ? relativePath : `ftp://${this.host.username}@${this.host.hostname}:${this.host.port}${this.localFile.remoteFile.path}`;
				} else {
					directory = atom.project.relativize(path.dirname(sessionPath));
					directory = directory.length > 0 ? directory : path.basename(path.dirname(sessionPath));
				}

				return `${fileName} - ${directory}`;
			}

			onDidSaved(callback) {
				return this.emitter.on('did-saved', callback);
			}

			save() {
				var self = this
				// I think, here we need a new promise, since the buffer.save()
				// one will most probably resolve... while the inner one is
				// prone to failure
				return new Promise(function(resolve, reject){
					self.buffer.save().then(function(result) {
						self.initiateUpload().then(
							function() {
								self.emitter.emit('saved');
								if (atom.config.get('remote-edit-ni.uploadOptions.closeOnUpload'))
									self.host.close();
								if (!self.checkTimer)
									self.startRefresh();
								resolve()
							},
							function(err) {
								self.buffer.append("\n")
								reject(err)
							}
						)
					})
				})

			}

			saveAs(filePath) {
				this.buffer.saveAs(filePath);
				this.localFile.path = filePath;
				this.emitter.emit('saved');
				return this.initiateUpload();
			}

			initiateUpload() {
				if (atom.config.get('remote-edit-ni.uploadOptions.uploadOnSave')) {
					return this.upload();
				} else {
					if (Dialog == null) {
						Dialog = require('../view/dialog');
					}
					const chosen = atom.confirm({
						message: "File has been saved. Do you want to upload changes to remote host?",
						detailedMessage: "The changes exists on disk and can be uploaded later.",
						buttons: ["Upload", "Cancel"]
					});
					switch (chosen) {
						case 0:
							return this.upload();
						case 1:
							return;
					}
				}
			}

			upload(connectionOptions) {
				var self = this
				return new Promise(function(resolve, reject) {

					if (connectionOptions == null) {
						connectionOptions = {};
					}
					if (async == null) {
						async = require('async');
					}
					if (_ == null) {
						_ = require('underscore-plus');
					}

					if ((self.localFile == null) || (self.host == null)) {
						reject()
						return console.error('LocalFile and host not defined. Cannot upload file!');
					}

					async.waterfall([
						callback => {
							if (!self.host.usePassword || (connectionOptions.password == null)) {
								return callback(null);
							}

							if (!!self.host.password) {
								return callback(null);
							}

							return async.waterfall([
								function(callback) {
									if (Dialog == null) {
										Dialog = require('../view/dialog');
									}
									const passwordDialog = new Dialog({
										prompt: "Enter password", type: 'password'
									});
									return passwordDialog.toggle(callback);
								}
							], (err, result) => {
								connectionOptions = _.extend({
									password: result
								}, connectionOptions);
								return callback(null);
							});

						},
						callback => {
							if (!self.host.isConnected()) {
								return self.host.connect(callback, connectionOptions);
							} else {
								return callback(null);
							}
						},
						callback => {
							// Resolve only after we write the file on the remote
							// and only if the write was successfull
							self.host.writeFile(self.localFile, (err) => {
								if (!err) resolve()
								callback(err)
							});
						}
					], err => {
						if ((err != null) && self.host.usePassword) {
							return async.waterfall([
								function(callback) {
									if (Dialog == null) {
										Dialog = require('../view/dialog');
									}
									const passwordDialog = new Dialog({
										prompt: "Enter password"
									});
									return passwordDialog.toggle(callback);
								}
							], (err, result) => {
								return self.upload({
									password: result
								});
							});

						} else if (err != null) {
							console.log("Rejecting!")
							reject(err)
						}
					});
				})
			}

			serialize () {
				return {
					deserializer: 'RemoteEditEditor',
					version: SERIALIZATION_VERSION,

					displayLayerId: this.displayLayer.id,
					selectionsMarkerLayerId: this.selectionsMarkerLayer.id,

					initialScrollTopRow: this.getScrollTopRow(),
					initialScrollLeftColumn: this.getScrollLeftColumn(),

					tabLength: this.displayLayer.tabLength,
					atomicSoftTabs: this.displayLayer.atomicSoftTabs,
					softWrapHangingIndentLength: this.displayLayer.softWrapHangingIndent,

					id: this.id,
					bufferId: this.buffer.id,
					softTabs: this.softTabs,
					softWrapped: this.softWrapped,
					softWrapAtPreferredLineLength: this.softWrapAtPreferredLineLength,
					preferredLineLength: this.preferredLineLength,
					mini: this.mini,
					readOnly: this.readOnly,
					editorWidthInChars: this.editorWidthInChars,
					width: this.width,
					maxScreenLineLength: this.maxScreenLineLength,
					registered: this.registered,
					invisibles: this.invisibles,
					showInvisibles: this.showInvisibles,
					showIndentGuide: this.showIndentGuide,
					autoHeight: this.autoHeight,
					autoWidth: this.autoWidth,

					reLocalFile: this.localFile != null ? this.localFile.serialize() : undefined,
					reHost: this.host != null ? this.host.serialize() : undefined
				}
			}

			static deserialize (state, atomEnvironment) {

				if (state.version !== SERIALIZATION_VERSION) return null

				let bufferId = state.tokenizedBuffer
					? state.tokenizedBuffer.bufferId
					: state.bufferId

				try {
					state.buffer = atomEnvironment.project.bufferForIdSync(bufferId)
					if (!state.buffer) return null
				} catch (error) {
					if (error.syscall === 'read') {
						return // Error reading the file, don't deserialize an editor for it
					} else {
						throw error
					}
				}

				state.assert = atomEnvironment.assert.bind(atomEnvironment)
				const editor = new RemoteEditEditor(state)
				if (state.registered) {
					const disposable = atomEnvironment.textEditors.add(editor)
					editor.onDidDestroy(() => {
						disposable.dispose()
					})
				}
				return editor
			}
		};
		RemoteEditEditor.initClass();
		return RemoteEditEditor;
	})());
