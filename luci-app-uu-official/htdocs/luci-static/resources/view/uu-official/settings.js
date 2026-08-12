'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		var m = new form.Map('uu-official', _('NetEase UU'),
			_('Manage the NetEase-distributed UU router runtime. This open-source package does not include the proprietary UU binary.'));
		var s = m.section(form.NamedSection, 'main', 'main', _('Settings'));
		s.anonymous = true;

		var enabled = s.option(form.Flag, 'enabled', _('Enable service'));
		enabled.default = enabled.disabled;
		enabled.rmempty = false;

		var model = s.option(form.ListValue, 'model', _('Runtime architecture'));
		model.value('auto', _('Automatic detection'));
		model.value('x86_64', 'x86_64');
		model.value('aarch64', 'AArch64');
		model.value('arm', 'ARM');
		model.value('mipsel', 'MIPS little-endian');
		model.value('mipseb', 'MIPS big-endian');
		model.default = 'auto';
		model.rmempty = false;
		model.description = _('Use automatic detection unless the official API requires a manual override.');

		return m.render();
	}
});

