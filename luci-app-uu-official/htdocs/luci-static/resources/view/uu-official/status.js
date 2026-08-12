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

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(manager, [ 'status' ]), { stdout: 'unknown' }),
			L.resolveDefault(fs.read('/tmp/monitor.log'), '')
		]);
	},

	render: function(data) {
		var status = parseStatus(data[0].stdout);
		var statusNode = E('div');
		var logNode = E('pre', {
			'class': 'logtext',
			'style': 'max-height:420px;overflow:auto;white-space:pre-wrap'
		}, [ data[1] || _('No monitor log is available yet.') ]);

		function renderStatus(current) {
			dom.content(statusNode, E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, current.state === 'running' ? _('Running') : _('Stopped')),
				E('p', {}, [ _('PID: %s').format(current.pid || '-'), E('br'),
					_('Architecture: %s').format(current.model || '-'), E('br'),
					_('Official monitor: %s').format(current.monitor || '-') ])
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
		poll.add(function() {
			return L.resolveDefault(fs.exec(manager, [ 'status' ]), { stdout: 'unknown' })
				.then(function(res) { renderStatus(parseStatus(res.stdout)); });
		}, 5);

		return E([], [
			E('h2', {}, _('NetEase UU')),
			E('div', { 'class': 'cbi-map-descr' },
				_('The runtime and monitor script are downloaded from NetEase official distribution servers.')),
			statusNode,
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
