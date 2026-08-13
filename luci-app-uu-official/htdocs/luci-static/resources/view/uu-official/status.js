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
		var fields = line.substring(7).split('|');
		var item = { device: fields.shift() || '' };
		fields.forEach(function(field) {
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

function deviceKind(kind) {
	var kinds = {
		playstation: { label: _('PlayStation'), icon: 'PS' },
		switch: { label: _('Nintendo Switch'), icon: 'NS' },
		xbox: { label: _('Xbox'), icon: 'X' },
		mobile: { label: _('Mobile device'), icon: '▯' },
		computer: { label: _('Computer'), icon: '▱' },
		console: { label: _('Game console'), icon: '🎮' }
	};
	return kinds[kind] || kinds.console;
}

function latencyInfo(value) {
	var latency = parseFloat(value);
	if (!isFinite(latency))
		return { text: _('Unknown'), level: 'unknown', bars: 0 };
	if (latency < 10)
		return { text: latency.toFixed(1) + ' ms', level: 'excellent', bars: 4 };
	if (latency < 30)
		return { text: latency.toFixed(1) + ' ms', level: 'good', bars: 3 };
	if (latency < 80)
		return { text: latency.toFixed(1) + ' ms', level: 'fair', bars: 2 };
	return { text: latency.toFixed(1) + ' ms', level: 'poor', bars: 1 };
}

function renderDevice(device) {
	var kind = deviceKind(device.kind);
	var latency = latencyInfo(device.latency);
	return E('div', { 'class': 'uu-device-card uu-kind-' + (device.kind || 'console') }, [
		E('div', { 'class': 'uu-device-icon', 'title': kind.label }, [
			E('span', { 'class': 'uu-icon-glow' }),
			E('strong', {}, kind.icon)
		]),
		E('div', { 'class': 'uu-device-main' }, [
			E('div', { 'class': 'uu-device-title' }, [
				E('strong', {}, device.name || kind.label),
				E('span', { 'class': 'uu-online-pill' }, [ E('i'), _('Accelerating') ])
			]),
			E('div', { 'class': 'uu-device-address' }, device.device),
			E('div', { 'class': 'uu-device-meta' }, [
				E('span', {}, [ _('MAC'), ': ', device.mac || '-' ]),
				E('span', {}, [ _('Type'), ': ', kind.label ])
			])
		]),
		E('div', { 'class': 'uu-device-metrics' }, [
			E('div', { 'class': 'uu-latency ' + latency.level }, [
				E('div', { 'class': 'uu-latency-ring' }, [
					E('span', {}, latency.text),
					E('i'), E('i'), E('i')
				]),
				E('div', { 'class': 'uu-signal-bars' }, [ 1, 2, 3, 4 ].map(function(bar) {
					return E('i', { 'class': bar <= latency.bars ? 'on' : '' });
				}))
			]),
			E('div', { 'class': 'uu-packet-metric' }, [
				E('small', {}, _('Processed packets')),
				E('strong', {}, device.packets || '0'),
				E('span', { 'class': 'uu-packet-wave' }, [ E('i'), E('i'), E('i'), E('i'), E('i') ])
			])
		])
	]);
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
		var serviceNode = E('div');
		var devicesNode = E('div');
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
			var activeDevices = devices.devices.filter(function(device) {
				return device.device && device.device !== 'unresolved';
			});
			dom.content(serviceNode, E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service status')),
				E('div', { 'class': current.state === 'running' ? 'uu-service-state active' : 'uu-service-state' }, [
					E('span', { 'class': 'uu-state-dot' }),
					E('strong', {}, current.state === 'running' ? _('Running') : _('Stopped'))
				]),
				E('p', {}, [ _('PID: %s').format(current.pid || '-'), E('br'),
					_('Service enabled: %s').format(current.enabled === '1' ? _('Yes') : _('No')), E('br'),
					_('Architecture: %s').format(current.model || '-'), E('br'),
					_('Official monitor: %s').format(current.monitor || '-') ])
			]));
			dom.content(devicesNode, E('div', { 'class': 'cbi-section uu-devices-section' }, [
				E('h3', {}, _('Acceleration devices')),
				activeDevices.length ? E('div', { 'class': 'uu-accelerating-banner' }, [
					E('span', { 'class': 'uu-radar' }),
					E('strong', {}, _('Acceleration active')),
					E('span', { 'class': 'uu-flow-dots' }, [ E('i'), E('i'), E('i') ])
				]) : E('div', { 'class': 'uu-detecting-banner' }, [
					E('span', { 'class': 'uu-scanner' }),
					E('span', {}, current.state === 'running' ? _('Waiting for an accelerated device') : _('Start the service to detect devices'))
				]),
				activeDevices.length ? E('div', { 'class': 'uu-device-grid' }, activeDevices.map(renderDevice)) : E('p', { 'class': 'alert-message warning' }, devices.reason === 'activation_state_missing' ? _('UU has not published an activation state yet. Open the UU mobile app, bind the router and a device, then refresh.') : _('No accelerated device has been identified by UU yet. Open the UU mobile app and bind a device first.')),
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
			E('style', {}, [
				'@keyframes uu-pulse{0%{transform:scale(.7);opacity:.35}50%{transform:scale(1.35);opacity:1}100%{transform:scale(.7);opacity:.35}}',
				'@keyframes uu-radar{0%{box-shadow:0 0 0 0 rgba(46,204,113,.65)}70%{box-shadow:0 0 0 12px rgba(46,204,113,0)}100%{box-shadow:0 0 0 0 rgba(46,204,113,0)}}',
				'@keyframes uu-scan{0%{transform:translateX(0);opacity:.25}50%{opacity:1}100%{transform:translateX(28px);opacity:.25}}',
				'@keyframes uu-wave{0%,100%{height:4px}50%{height:16px}}@keyframes uu-orbit{from{transform:rotate(0)}to{transform:rotate(360deg)}}',
				'.uu-service-state{display:flex;align-items:center;gap:9px;font-size:1.15em}.uu-state-dot,.uu-radar{display:inline-block;width:10px;height:10px;border-radius:50%;background:#999}.uu-service-state.active .uu-state-dot,.uu-radar{background:#2ecc71;animation:uu-pulse 1.4s infinite}.uu-accelerating-banner,.uu-detecting-banner{display:flex;align-items:center;gap:10px;padding:12px 14px;margin:8px 0 14px;border-radius:8px;background:linear-gradient(100deg,rgba(46,204,113,.16),rgba(52,152,219,.08));color:#199447}.uu-detecting-banner{background:rgba(127,127,127,.1);color:inherit}.uu-radar{animation:uu-radar 1.5s infinite}.uu-scanner{display:inline-block;width:7px;height:7px;border-radius:50%;background:#3498db;animation:uu-scan 1.2s ease-in-out infinite alternate}.uu-flow-dots i{display:inline-block;width:5px;height:5px;margin-left:5px;border-radius:50%;background:#2ecc71;animation:uu-pulse 1.2s infinite}.uu-flow-dots i:nth-child(2){animation-delay:.2s}.uu-flow-dots i:nth-child(3){animation-delay:.4s}.uu-device-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(430px,1fr));gap:14px}.uu-device-card{display:grid;grid-template-columns:76px minmax(170px,1fr) minmax(190px,auto);gap:16px;align-items:center;padding:18px;border:1px solid rgba(127,127,127,.2);border-radius:14px;background:linear-gradient(135deg,rgba(255,255,255,.06),rgba(52,152,219,.06));box-shadow:0 8px 24px rgba(0,0,0,.08);transition:transform .25s,box-shadow .25s}.uu-device-card:hover{transform:translateY(-2px);box-shadow:0 12px 30px rgba(0,0,0,.14)}.uu-device-icon{position:relative;display:flex;align-items:center;justify-content:center;width:64px;height:64px;border-radius:18px;background:linear-gradient(145deg,#1473e6,#06469b);color:#fff;font-size:21px;letter-spacing:-2px;overflow:hidden}.uu-kind-switch .uu-device-icon{background:linear-gradient(145deg,#e60012,#ff5763)}.uu-kind-xbox .uu-device-icon{background:linear-gradient(145deg,#107c10,#52b043)}.uu-icon-glow{position:absolute;width:52px;height:52px;border:2px solid rgba(255,255,255,.32);border-radius:50%;animation:uu-orbit 4s linear infinite}.uu-device-title{display:flex;align-items:center;gap:10px;font-size:1.15em}.uu-online-pill{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;border-radius:999px;background:rgba(46,204,113,.14);color:#199447;font-size:.72em}.uu-online-pill i{width:6px;height:6px;border-radius:50%;background:#2ecc71;animation:uu-pulse 1.2s infinite}.uu-device-address{margin:5px 0;font-family:monospace;font-size:1.15em}.uu-device-meta{display:flex;flex-wrap:wrap;gap:6px 16px;color:#888;font-size:.86em}.uu-device-metrics{display:flex;align-items:center;justify-content:flex-end;gap:24px}.uu-latency-ring{position:relative;display:flex;align-items:center;justify-content:center;width:72px;height:72px;border:3px solid #2ecc71;border-radius:50%;color:#21a85b;font-weight:bold}.uu-latency-ring>i{position:absolute;inset:-7px;border:1px solid currentColor;border-radius:50%;opacity:.14;animation:uu-radar 2s infinite}.uu-latency-ring>i:nth-child(2){animation-delay:.45s}.uu-latency-ring>i:nth-child(3){animation-delay:.9s}.uu-latency.good .uu-latency-ring{border-color:#8bc34a;color:#689f38}.uu-latency.fair .uu-latency-ring{border-color:#f1c40f;color:#d4a900}.uu-latency.poor .uu-latency-ring{border-color:#e74c3c;color:#e74c3c}.uu-latency.unknown .uu-latency-ring{border-color:#999;color:#999}.uu-signal-bars{display:flex;align-items:flex-end;justify-content:center;gap:3px;height:14px;margin-top:7px}.uu-signal-bars i{width:4px;height:4px;border-radius:2px;background:#bbb}.uu-signal-bars i:nth-child(2){height:7px}.uu-signal-bars i:nth-child(3){height:10px}.uu-signal-bars i:nth-child(4){height:14px}.uu-signal-bars i.on{background:currentColor}.uu-packet-metric{min-width:92px;text-align:right}.uu-packet-metric small{display:block;color:#888}.uu-packet-metric strong{display:block;margin:3px 0;font-size:1.45em;font-variant-numeric:tabular-nums}.uu-packet-wave{display:flex;align-items:center;justify-content:flex-end;gap:3px;height:18px}.uu-packet-wave i{display:block;width:3px;height:5px;border-radius:2px;background:#3498db;animation:uu-wave 1s ease-in-out infinite}.uu-packet-wave i:nth-child(2){animation-delay:.12s}.uu-packet-wave i:nth-child(3){animation-delay:.24s}.uu-packet-wave i:nth-child(4){animation-delay:.36s}.uu-packet-wave i:nth-child(5){animation-delay:.48s}@media(max-width:700px){.uu-device-grid{grid-template-columns:1fr}.uu-device-card{grid-template-columns:58px 1fr}.uu-device-icon{width:52px;height:52px}.uu-device-metrics{grid-column:1/-1;justify-content:space-around;border-top:1px solid rgba(127,127,127,.15);padding-top:12px}}'
			]),
			E('h2', {}, _('NetEase UU')),
			E('div', { 'class': 'cbi-map-descr' },
				_('The runtime and monitor script are downloaded from NetEase official distribution servers.')),
			messageNode,
			serviceNode,
			devicesNode,
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
