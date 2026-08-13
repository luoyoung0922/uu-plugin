'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require dom';

var manager = '/usr/libexec/uu-official/manager.sh';

function exec(path, args) {
	return fs.exec(path, args || []).then(function(res) {
		if (res.code !== 0)
			throw new Error((res.stderr || res.stdout || _('Command failed')).trim());
		return res;
	});
}

function timeout(promise, seconds) {
	return Promise.race([
		promise,
		new Promise(function(resolve, reject) {
			window.setTimeout(function() { reject(new Error(_('Command timed out. Check the live log for details.'))); }, seconds * 1000);
		})
	]);
}

function parseStatus(text) {
	var lines = (text || '').trim().split(/\n/);
	var data = { state: lines.shift() || 'unknown' };
	lines.forEach(function(line) {
		var pos = line.indexOf('=');
		if (pos > 0)
			data[line.substring(0, pos)] = line.substring(pos + 1);
	});
	return data;
}

function parseDevices(text) {
	var data = { source: '', devices: [] };
	(text || '').trim().split(/\n/).forEach(function(line) {
		if (!line)
			return;
		if (line.indexOf('source=') === 0) {
			data.source = line.substring(7);
			return;
		}
		if (line.indexOf('reason=') === 0) {
			data.reason = line.substring(7);
			return;
		}
		if (line.indexOf('device=') !== 0)
			return;
		var item = {};
		line.substring(7).split('|').forEach(function(field) {
			var pos = field.indexOf('=');
			if (pos > 0)
				item[field.substring(0, pos)] = field.substring(pos + 1);
		});
		data.devices.push(item);
	});
	return data;
}

function deviceSource(source) {
	if (source === 'nftables/XU_ACC_DEVICE_*')
		return _('UU acceleration rules (nftables)');
	if (source && source.indexOf('/activate_status') > -1)
		return _('Official activation status');
	return source || _('not available');
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(manager, [ 'status' ]), { stdout: 'unknown' }),
			L.resolveDefault(fs.exec(manager, [ 'devices' ]), { stdout: '' })
		]);
	},

	render: function(data) {
		var status = parseStatus(data[0].stdout);
		var devices = parseDevices(data[1].stdout);
		var statusNode = E('div');
		var messageNode = E('div');
		var messageTimer = null;
		function showMessage(message, level) {
			if (messageTimer)
				window.clearTimeout(messageTimer);
			dom.content(messageNode, E('p', {
				'class': 'alert-message ' + (level === 'error' ? 'danger' : 'success')
			}, message));
			messageTimer = window.setTimeout(function() {
				dom.content(messageNode, '');
				messageTimer = null;
			}, 4000);
		}
		function refreshStatus() {
			return Promise.all([
				L.resolveDefault(fs.exec(manager, [ 'status' ]), { stdout: 'unknown' }),
				L.resolveDefault(fs.exec(manager, [ 'devices' ]), { stdout: '' })
			]).then(function(res) {
				devices = parseDevices(res[1].stdout);
				renderStatus(parseStatus(res[0].stdout));
			});
		}
		function renderStatus(current) {
			dom.content(statusNode, E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, current.state === 'running' ? _('Running') : _('Stopped')),
				E('p', {}, [ _('PID: %s').format(current.pid || '-'), E('br'),
					_('Service enabled: %s').format(current.enabled === '1' ? _('Yes') : _('No')), E('br'),
					_('Architecture: %s').format(current.model || '-'), E('br'),
					_('Official monitor: %s').format(current.monitor || '-') ]),
				E('h3', {}, _('Acceleration devices')),
				devices.devices.length ? E('table', { 'class': 'table' }, [
					E('tr', {}, [ E('th', {}, _('Device')), E('th', {}, _('MAC')), E('th', {}, _('UUID')), E('th', {}, _('Latency')), E('th', {}, _('Packets')) ])
				].concat(devices.devices.map(function(device) {
					return E('tr', {}, [ E('td', {}, device.name || device.device || _('Unresolved IP')),
						E('td', {}, device.mac || '-'), E('td', {}, device.uuid || '-'), E('td', {}, device.latency === 'unknown' ? _('Unknown') : (device.latency + ' ms')), E('td', {}, device.packets || '0') ]);
				}))) : E('p', { 'class': 'alert-message warning' }, devices.reason === 'activation_state_missing' ? _('UU has not published an activation state yet. Open the UU mobile app, bind the router and a device, then refresh.') : _('No accelerated device has been identified by UU yet. Open the UU mobile app and bind a device first.')),
				devices.reason === 'router_mac_only' ? E('p', { 'class': 'alert-message warning' }, _('UU has only reported the router MAC, not a phone/game device. Bind the target device in the UU mobile app and start acceleration there.')) : null,
				E('p', { 'class': 'cbi-map-descr' }, _('Device source: %s').format(deviceSource(devices.source)))
			]));
		}

		function action(button, path, args, success) {
			button.disabled = true;
			button.classList.add('spinning');
			return timeout(exec(path, args), 45).then(function() {
				showMessage(success, 'info');
			}).catch(function(err) {
				showMessage(err.message, 'error');
			}).then(function() {
				button.disabled = false;
				button.classList.remove('spinning');
				return refreshStatus();
			});
		}

		function reinstall(button) {
			button.disabled = true;
			button.classList.add('spinning');
			return timeout(exec(manager, [ 'stop' ])
				.then(function() { return exec(manager, [ 'clean-runtime' ]); })
				.then(function() { return exec(manager, [ 'start' ]); }), 90)
				.then(function() {
					showMessage(_('Runtime reinstall requested.'), 'info');
				}).catch(function(err) {
					showMessage(err.message, 'error');
				}).then(function() {
					button.disabled = false;
					button.classList.remove('spinning');
					return refreshStatus();
				});
		}

		renderStatus(status);
		poll.add(refreshStatus, 2);

		return E([], [
			E('h2', {}, _('NetEase UU')),
			E('div', { 'class': 'cbi-map-descr' },
				_('The runtime and monitor script are downloaded from NetEase official distribution servers.')),
			messageNode,
			statusNode,
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) { return action(ev.currentTarget, manager, [ 'start' ], _('Service start requested.')); }
				}, _('Start')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) { return action(ev.currentTarget, manager, [ 'restart' ], _('Service restarted.')); }
				}, _('Restart')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': function(ev) { return action(ev.currentTarget, manager, [ 'stop' ], _('Service stopped.')); }
				}, _('Stop')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': function(ev) { return action(ev.currentTarget, manager, [ 'update-monitor' ], _('Official monitor script updated; restart the service to apply it.')); }
				}, _('Update monitor')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': function() {
						return ui.showModal(_('Confirm runtime reinstall'), [
							E('p', {}, _('This stops UU, removes its downloaded runtime cache, and starts the service again. It does not change LuCI settings.')),
							E('div', { 'class': 'right' }, [
								E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
								E('button', { 'class': 'btn cbi-button-negative', 'click': function(ev) {
									ui.hideModal();
									return reinstall(ev.currentTarget);
								} }, _('Reinstall'))
							])
						]);
					}
				}, _('Reinstall runtime'))
			]),
			E('p', { 'class': 'alert-message warning' },
				_('The official API currently provides MD5 integrity values. MD5 detects accidental corruption but is not a cryptographic signature.'))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
