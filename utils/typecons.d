﻿/**
 * Complements the std.typecons package.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.typecons;

import std.typecons;

/// If `value` is not null, return its contents.
/// If `value` is null, set it to `defaultValue` and return it.
/// Similar to `object.require` for associative arrays, and
/// Rust's `Option::get_or_insert`.
ref T require(T)(ref Nullable!T value, lazy T defaultValue)
{
	if (value.isNull)
		value = defaultValue;
	return value.get();
}

///
unittest
{
	Nullable!int i;
	assert(i.require(3) == 3);
	assert(i.require(4) == 3);
}

deprecated alias map = std.typecons.apply;

deprecated unittest
{
	assert(Nullable!int( ).map!(n => n+1).isNull);
	assert(Nullable!int(1).map!(n => n+1).get() == 2);
}

/// Flatten two levels of Nullable.
// Cf. https://doc.rust-lang.org/std/option/enum.Option.html#method.flatten
Nullable!T flatten(T)(Nullable!(Nullable!T) value)
{
	return value.isNull
		? Nullable!T.init
		: value.get();
}

///
unittest
{
	auto i = 3.nullable.nullable;
	assert(i.flatten.get == 3);
}
