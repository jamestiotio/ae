﻿/**
 * HTTP / mail / etc. headers
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

module ae.net.ietf.headers;

import std.algorithm;
import std.string;
import std.ascii;
import std.exception;

import ae.utils.text;
import ae.utils.aa;

/// AA-like structure for storing headers, allowing for case
/// insensitivity and multiple values per key.
struct Headers
{
	private struct Header { string name, value; }

	private Header[][CIAsciiString] headers;

	/// Initialize from a D associative array.
	this(string[string] aa)
	{
		foreach (k, v; aa)
			this.add(k, v);
	}

	/// ditto
	this(string[][string] aa)
	{
		foreach (k, vals; aa)
			foreach (v; vals)
				this.add(k, v);
	}

	/// If multiple headers with this name are present,
	/// only the first one is returned.
	ref inout(string) opIndex(string name) inout pure
	{
		return headers[CIAsciiString(name)][0].value;
	}

	/// Sets the given header to the given value, overwriting any previous values.
	string opIndexAssign(string value, string name) pure
	{
		headers[CIAsciiString(name)] = [Header(name, value)];
		return value;
	}

	/// If the given header exists, return a pointer to the first value.
	/// Otherwise, return null.
	inout(string)* opBinaryRight(string op)(string name) inout @nogc
	if (op == "in")
	{
		auto pvalues = CIAsciiString(name) in headers;
		if (pvalues && (*pvalues).length)
			return &(*pvalues)[0].value;
		return null;
	}

	/// Remove the given header.
	/// Does nothing if the header was not present.
	void remove(string name) pure
	{
		headers.remove(CIAsciiString(name));
	}

	/// Iterate over all headers, including multiple instances of the seame header.
	int opApply(int delegate(ref string name, ref string value) dg)
	{
		int ret;
		outer:
		foreach (key, values; headers)
			foreach (header; values)
			{
				ret = dg(header.name, header.value);
				if (ret)
					break outer;
			}
		return ret;
	}

	// Copy-paste because of https://issues.dlang.org/show_bug.cgi?id=7543
	/// ditto
	int opApply(int delegate(ref const(string) name, ref const(string) value) dg) const
	{
		int ret;
		outer:
		foreach (name, values; headers)
			foreach (header; values)
			{
				ret = dg(header.name, header.value);
				if (ret)
					break outer;
			}
		return ret;
	}

	/// Add a value for the given header.
	/// Adds a new instance of the header if one already existed.
	void add(string name, string value) pure
	{
		auto key = CIAsciiString(name);
		if (key !in headers)
			headers[key] = [Header(name, value)];
		else
			headers[key] ~= Header(name, value);
	}

	/// Retrieve the value of the given header if it is present, otherwise return `def`.
	string get(string key, string def) const pure nothrow @nogc
	{
		auto pvalue = key in this;
		return pvalue ? *pvalue : def;
	}

	/// Lazy version of `get`.
	string getLazy(string key, lazy string def) const pure /*nothrow*/ /*@nogc*/
	{
		auto pvalue = key in this;
		return pvalue ? *pvalue : def;
	}

	/// Retrieve all values of the given header.
	inout(string)[] getAll(string key) inout pure
	{
		inout(string)[] result;
		foreach (header; headers.get(CIAsciiString(key), null))
			result ~= header.value;
		return result;
	}

	/// If the given header is not yet present, add it with the given value.
	ref string require(string key, lazy string value) pure
	{
		return headers.require(CIAsciiString(key), [Header(key, value)])[0].value;
	}

	/// True-ish if any headers have been set.
	bool opCast(T)() const pure nothrow @nogc
		if (is(T == bool))
	{
		return !!headers;
	}

	/// Converts to a D associative array,
	/// with at most one value per header.
	/// Warning: discards repeating headers!
	string[string] opCast(T)() const
		if (is(T == string[string]))
	{
		string[string] result;
		foreach (key, value; this)
			result[key] = value;
		return result;
	}

	/// Converts to a D associative array.
	string[][string] opCast(T)() inout
		if (is(T == string[][string]))
	{
		string[][string] result;
		foreach (k, v; this)
			result[k] ~= v;
		return result;
	}

	/// Creates and returns a copy of this `Headers` instance.
	@property Headers dup() const
	{
		Headers c;
		foreach (k, v; this)
			c.add(k, v);
		return c;
	}

	/// Returns the number of headers and values (including duplicate headers).
	@property size_t length() const pure nothrow @nogc
	{
		return headers.length;
	}
}

unittest
{
	Headers headers;
	headers["test"] = "test";

	void test(T)(T headers)
	{
		assert("TEST" in headers);
		assert(headers["TEST"] == "test");

		foreach (k, v; headers)
			assert(k == "test" && v == "test");

		auto aas = cast(string[string])headers;
		assert(aas == ["test" : "test"]);

		auto aaa = cast(string[][string])headers;
		assert(aaa == ["test" : ["test"]]);
	}

	test(headers);

	const constHeaders = headers;
	test(constHeaders);
}

/// Attempts to normalize the capitalization of a header name to a
/// likely form.
/// This involves capitalizing all words, plus rules to uppercase
/// common acronyms used in header names, such as "IP" and "ETag".
string normalizeHeaderName(string header) pure
{
	alias std.ascii.toUpper toUpper;
	alias std.ascii.toLower toLower;

	auto s = header.dup;
	auto segments = s.split("-");
	foreach (segment; segments)
	{
		foreach (ref c; segment)
			c = cast(char)toUpper(c);
		switch (segment)
		{
			case "ID":
			case "IP":
			case "NNTP":
			case "TE":
			case "WWW":
				continue;
			case "ETAG":
				segment[] = "ETag";
				break;
			default:
				foreach (ref c; segment[1..$])
					c = cast(char)toLower(c);
				break;
		}
	}
	return s;
}

unittest
{
	assert(normalizeHeaderName("X-ORIGINATING-IP") == "X-Originating-IP");
}

/// Decodes headers of the form
/// `"main-value; param1=value1; param2=value2"`
struct TokenHeader
{
	string value; /// The main header value.
	string[string] properties; /// Following properties, as a D associative array.
}

/// ditto
TokenHeader decodeTokenHeader(string s)
{
	string take(char until)
	{
		string result;
		auto p = s.indexOf(until);
		if (p < 0)
			result = s,
			s = null;
		else
			result = s[0..p],
			s = asciiStrip(s[p+1..$]);
		return result;
	}

	TokenHeader result;
	result.value = take(';');

	while (s.length)
	{
		string name = take('=').toLower();
		string value;
		if (s.length && s[0] == '"')
		{
			s = s[1..$];
			value = take('"');
			take(';');
		}
		else
			value = take(';');
		result.properties[name] = value;
	}

	return result;
}
