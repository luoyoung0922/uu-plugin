'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require dom';

var manager = '/usr/libexec/uu-official/manager.sh';
var init = '/etc/init.d/uu-official';

function exec(path, args) {
	return fs.exec(path, args || []).then(function(res) {
		if (res.code !== 0)
			throw new Error((res.stderr || res.stdout || _('Command failed')).trim());
		return res;
	});
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

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(manager, [ 'status' ]), { stdout: 'unknown' }),
			L.resolveDefault(fs.exec(manager, [ 'devices' ]), { stdout: '' }),
			L.resolveDefault(fs.read('/tmp/monitor.log'), ''),
			L.resolveDefault(fs.exec(manager, [ 'dns-status' ]), { stdout: '' })
		]);
	},

	render: function(data) {
		var status = parseStatus(data[0].stdout);
		var devices = parseDevices(data[1].stdout);
		var dns = parseStatus('dns\n' + data[3].stdout);
		var statusNode = E('div');
		var dnsNode = E('div');
		var logNode = E('pre', {
			'class': 'logtext',
			'style': 'max-height:420px;overflow:auto;white-space:pre-wrap'
		}, [ data[2] || _('No monitor log is available yet.') ]);

		function renderStatus(current) {
			dom.content(statusNode, E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, current.state === 'running' ? _('Running') : _('Stopped')),
				E('p', {}, [ _('PID: %s').format(current.pid || '-'), E('br'),
					_('Service enabled: %s').format(current.enabled === '1' ? _('Yes') : _('No')), E('br'),
					_('Architecture: %s').format(current.model || '-'), E('br'),
					_('Official monitor: %s').format(current.monitor || '-') ]),
				E('h3', {}, _('Acceleration devices')),
				devices.devices.length ? E('table', { 'class': 'table' }, [
					E('tr', {}, [ E('th', {}, _('Device')), E('th', {}, _('MAC')), E('th', {}, _('UUID')), E('th', {}, _('Latency')) ])
				].concat(devices.devices.map(function(device) {
					return E('tr', {}, [ E('td', {}, device.name || device.device || _('Unresolved IP')),
						E('td', {}, device.mac || '-'), E('td', {}, device.uuid || '-'), E('td', {}, device.latency === 'unknown' ? _('Unknown') : (device.latency + ' ms')) ]);
				}))) : E('p', { 'class': 'alert-message warning' }, devices.reason === 'activation_state_missing' ? _('UU has not published an activation state yet. Open the UU mobile app, bind the router and a device, then refresh.') : _('No accelerated device has been identified by UU yet. Open the UU mobile app and bind a device first.')),
				E('p', { 'class': 'cbi-map-descr' }, _('Device source: %s').format(devices.source || _('not available')))
			]));
		}

		function renderDns(current) {
			var openclash = current.openclash_running === '1';
			var conflict = openclash && (current.uu_fake_ip === '1' || current.dns_hijack === '1');
			var rules = 'DOMAIN-SUFFIX,uu.163.com,DIRECT\n' +
				'DOMAIN-SUFFIX,163.com,DIRECT\n' +
				'DOMAIN-SUFFIX,netease.com,DIRECT\n' +
				'DOMAIN-SUFFIX,netease.com.cn,DIRECT\n' +
				'DOMAIN-SUFFIX,uuzu.com,DIRECT';
			dom.content(dnsNode, E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('OpenClash / DNS compatibility')),
				E('p', { 'class': conflict ? 'alert-message warning' : 'alert-message success' },
					conflict ? _('A possible DNS conflict was detected. Add the rules below to OpenClash and exclude UU domains from Fake-IP.') : _('No obvious UU DNS conflict was detected.')),
				E('p', {}, [
					_('OpenClash running: %s').format(openclash ? _('Yes') : _('No')), E('br'),
					_('DNS mode: %s').format(current.dns_mode || '-'), E('br'),
					_('DNS hijack: %s').format(current.dns_hijack || '-'), E('br'),
					_('Port 53 listeners: %s').format(current.dns_listeners || '-'), E('br'),
					_('UU DNS result: %s').format(current.uu_resolved || '-')
				]),
				E('p', { 'class': 'cbi-map-descr' }, _('Recommended OpenClash custom direct rules:')),
				E('pre', { 'style': 'white-space:pre-wrap;user-select:all' }, [ rules ]),
				E('p', { 'class': 'cbi-map-descr' }, _('When using Fake-IP mode, also add the UU domains above to the Fake-IP filter. This page only diagnoses the configuration and never changes OpenClash automatically.'))
			]));
		}

		function action(path, args, success) {
			ui.showModal(_('Please wait…'), [ E('p', { 'class': 'spinning' }, _('Running command…')) ]);
			return exec(path, args).then(function() {
				ui.hideModal();
				ui.addNotification(null, E('p', success), 'info');
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', err.message), 'error');
			});
		}

		function reinstall() {
			ui.showModal(_('Please wait…'), [ E('p', { 'class': 'spinning' }, _('Running command…')) ]);
			return exec(init, [ 'stop' ])
				.then(function() { return exec(manager, [ 'clean-runtime' ]); })
				.then(function() { return exec(init, [ 'start' ]); })
				.then(function() {
					ui.hideModal();
					ui.addNotification(null, E('p', _('Runtime reinstall requested.')), 'info');
				}).catch(function(err) {
					ui.hideModal();
					ui.addNotification(null, E('p', err.message), 'error');
				});
		}

		renderStatus(status);
		renderDns(dns);
		poll.add(function() {
			return Promise.all([
				L.resolveDefault(fs.exec(manager, [ 'status' ]), { stdout: 'unknown' }),
				L.resolveDefault(fs.exec(manager, [ 'devices' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(manager, [ 'dns-status' ]), { stdout: '' })
			]).then(function(res) {
				devices = parseDevices(res[1].stdout);
				renderStatus(parseStatus(res[0].stdout));
				renderDns(parseStatus('dns\n' + res[2].stdout));
			});
		}, 5);

		return E([], [
			E('h2', {}, _('NetEase UU')),
			E('div', { 'class': 'cbi-map-descr' },
				_('The runtime and monitor script are downloaded from NetEase official distribution servers.')),
			statusNode,
			dnsNode,
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() { return action(init, [ 'start' ], _('Service start requested.')); }
				}, _('Start')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() { return action(init, [ 'restart' ], _('Service restarted.')); }
				}, _('Restart')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': function() { return action(init, [ 'stop' ], _('Service stopped.')); }
				}, _('Stop')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': function() { return action(manager, [ 'update-monitor' ], _('Official monitor script updated; restart the service to apply it.')); }
				}, _('Update monitor')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': function() {
						return ui.showModal(_('Confirm runtime reinstall'), [
							E('p', {}, _('This stops UU, removes its downloaded runtime cache, and starts the service again. It does not change LuCI settings.')),
							E('div', { 'class': 'right' }, [
								E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
								E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
									ui.hideModal();
									return reinstall();
								} }, _('Reinstall'))
							])
						]);
					}
				}, _('Reinstall runtime'))
			]),
			E('h3', {}, _('Monitor log')),
			logNode,
			E('p', { 'class': 'alert-message warning' },
				_('The official API currently provides MD5 integrity values. MD5 detects accidental corruption but is not a cryptographic signature.'))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
