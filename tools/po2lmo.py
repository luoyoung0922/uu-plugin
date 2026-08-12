#!/usr/bin/env python3
"""Build a LuCI .lmo catalog from a simple gettext .po file."""

import ast
import struct
import sys


def parse_po(path):
	entries = []
	msgid = msgstr = None
	field = None

	def finish():
		nonlocal msgid, msgstr
		if msgid and msgstr and msgid != msgstr:
			entries.append((msgid.encode(), msgstr.encode()))
		msgid = msgstr = None

	with open(path, encoding='utf-8') as source:
		for raw in source:
			line = raw.strip()
			if line.startswith('msgid '):
				finish()
				field = 'id'
				msgid = ast.literal_eval(line[6:])
			elif line.startswith('msgstr '):
				field = 'str'
				msgstr = ast.literal_eval(line[7:])
			elif line.startswith('"'):
				value = ast.literal_eval(line)
				if field == 'id':
					msgid = (msgid or '') + value
				elif field == 'str':
					msgstr = (msgstr or '') + value
	finish()
	return entries


def sfh(data):
	mask = 0xffffffff
	hash_value = len(data)
	pos = 0
	blocks, remainder = divmod(len(data), 4)
	for _ in range(blocks):
		low = data[pos] | (data[pos + 1] << 8)
		high = data[pos + 2] | (data[pos + 3] << 8)
		hash_value = (hash_value + low) & mask
		tmp = ((high << 11) ^ hash_value) & mask
		hash_value = ((hash_value << 16) ^ tmp) & mask
		pos += 4
		hash_value = (hash_value + (hash_value >> 11)) & mask
	if remainder == 3:
		hash_value = (hash_value + data[pos] + (data[pos + 1] << 8)) & mask
		hash_value ^= (hash_value << 16) & mask
		signed = data[pos + 2] if data[pos + 2] < 128 else data[pos + 2] - 256
		hash_value ^= (signed << 18) & mask
		hash_value = (hash_value + (hash_value >> 11)) & mask
	elif remainder == 2:
		hash_value = (hash_value + data[pos] + (data[pos + 1] << 8)) & mask
		hash_value ^= (hash_value << 11) & mask
		hash_value = (hash_value + (hash_value >> 17)) & mask
	elif remainder == 1:
		signed = data[pos] if data[pos] < 128 else data[pos] - 256
		hash_value = (hash_value + signed) & mask
		hash_value ^= (hash_value << 10) & mask
		hash_value = (hash_value + (hash_value >> 1)) & mask
	for shift, operation in ((3, 'xor-left'), (5, 'add-right'), (4, 'xor-left'),
			(17, 'add-right'), (25, 'xor-left'), (6, 'add-right')):
		if operation == 'xor-left':
			hash_value ^= (hash_value << shift) & mask
		else:
			hash_value = (hash_value + (hash_value >> shift)) & mask
	return hash_value & mask


def build(source, target):
	data = bytearray()
	index = []
	for key, value in parse_po(source):
		offset = len(data)
		data.extend(value)
		data.extend(b'\0' * ((-len(value)) % 4))
		index.append((sfh(key), 1, offset, len(value)))
	index.sort(key=lambda item: item[0])
	with open(target, 'wb') as output:
		output.write(data)
		for entry in index:
			output.write(struct.pack('!IIII', *entry))
		output.write(struct.pack('!I', len(data)))


if __name__ == '__main__':
	if len(sys.argv) != 3:
		raise SystemExit('usage: po2lmo.py input.po output.lmo')
	build(sys.argv[1], sys.argv[2])
