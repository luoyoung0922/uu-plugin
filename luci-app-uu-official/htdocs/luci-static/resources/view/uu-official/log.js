'use strict';
'require view';
'require fs';
'require poll';
'require dom';

var logPath = '/tmp/monitor.log';

return view.extend({
	load: function() {
		return L.resolveDefault(fs.read(logPath), '');
	},

	render: function(data) {
		var following = true;
		var logNode = E('pre', {
			'class': 'logtext',
			'style': 'height:65vh;min-height:360px;overflow:auto;white-space:pre-wrap;word-break:break-all;background:#1e1e1e;color:#e6e6e6;padding:12px;border-radius:4px'
		});
		var followButton = E('button', {
			'class': 'btn cbi-button cbi-button-action'
		});

		function updateButton() {
			dom.content(followButton, following ? _('Pause auto-scroll') : _('Resume auto-scroll'));
		}

		function updateLog(text) {
			dom.content(logNode, text || _('No monitor log is available yet.'));
			if (following)
				logNode.scrollTop = logNode.scrollHeight;
		}

		followButton.addEventListener('click', function() {
			following = !following;
			updateButton();
			if (following)
				logNode.scrollTop = logNode.scrollHeight;
		});

		updateButton();
		updateLog(data);
		poll.add(function() {
			return L.resolveDefault(fs.read(logPath), '').then(updateLog);
		}, 2);

		return E([], [
			E('h2', {}, _('Live log')),
			E('div', { 'class': 'cbi-map-descr' }, _('The monitor log refreshes every two seconds.')),
			E('div', { 'class': 'cbi-section' }, [ followButton, ' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': function() { logNode.scrollTop = logNode.scrollHeight; }
				}, _('Scroll to bottom'))
			]),
			logNode
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
