/**
	File system based database controller.

	Copyright: 2015-2018 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.db.file;

import userman.db.controller;

import vibe.core.file;
import vibe.data.json;
import vibe.textfilter.urlencode;
import vibe.utils.validation;

import std.datetime;
import std.exception;
import std.string;
import std.conv;
import std.uuid;


class FileUserManController : UserManController {
	private {
		NativePath m_basePath;
	}

	this(UserManSettings settings)
	{
		super(settings);

		enforce(settings.databaseURL.startsWith("file://"),
			"Database URL must have a file:// schema.");

		m_basePath = cast(NativePath)URL(settings.databaseURL).path;
		string[] paths = [".", "user", "user/byName", "user/byEmail", "group", "group/byName"];
		foreach (p; paths)
			if (!existsFile(m_basePath ~ p))
				createDirectory(m_basePath ~ p);
	}

	override bool isEmailRegistered(string email)
	{
		return existsFile(userByEmailFile(email));
	}

	private final NativePath userByNameFile(string name) @safe { return m_basePath ~ "user/byName/" ~ (urlEncode(name) ~ ".json"); }
	private final NativePath userByEmailFile(string email) @safe { return m_basePath ~ "user/byEmail/" ~ (urlEncode(email) ~ ".json"); }
	private final NativePath userFile(User.ID id) @safe { return m_basePath ~ "user/" ~ (id.toString() ~ ".json"); }
	private final NativePath groupFile(string id) @safe in { assert(isValidGroupID(id)); } body { return m_basePath ~ ("group/" ~ id ~ ".json"); }

	override User.ID addUser(ref User usr)
	{
		validateUser(usr);
		enforce(!isEmailRegistered(usr.email), "The email address is already taken.");
		enforce(!existsFile(userByNameFile(usr.name)), "The user name is already taken.");

		usr.id = User.ID(randomUUID());
		if (usr.resetCodeExpireTime == SysTime.init)
			usr.resetCodeExpireTime = SysTime(0);

		// Indexes
		writeJsonFile(userByEmailFile(usr.email), usr.id);
		scope (failure) removeFile(userByEmailFile(usr.email));
		writeJsonFile(userByNameFile(usr.name), usr.id);
		scope (failure) removeFile(userByNameFile(usr.name));

		writeJsonFile(userFile(usr.id), usr);

		return usr.id;
	}

	override User getUser(User.ID id)
	{
		return readJsonFile!User(userFile(id));
	}

	override User getUserByName(string name)
	{
		name = name.toLower();
		auto uid = User.ID.fromString(readFileUTF8(userByNameFile(name)).deserializeJson!string);
		return getUser(uid);
	}

	override User getUserByEmail(string email)
	{
		email = email.toLower();
		auto uid = User.ID.fromString(readFileUTF8(userByEmailFile(email)).deserializeJson!string);
		return getUser(uid);
	}

	override User getUserByEmailOrName(string email_or_name)
	{
		if (isEmailRegistered(email_or_name)) return getUserByEmail(email_or_name);
		else return getUserByName(email_or_name);
	}

	alias enumerateUsers = UserManController.enumerateUsers;
	override void enumerateUsers(long first_user, long max_count, scope void delegate(ref User usr) @safe del)
	{
		listDirectory(m_basePath ~ "user/", (de) {
			if (!de.name.endsWith(".json") || de.isDirectory) return true;
			if (first_user > 0) {
				first_user--;
				return true;
			}
			if (max_count-- <= 0) return false;
			auto usr = getUser(User.ID.fromString(de.name[0 .. $-5]));
			del(usr);
			return true;
		});
	}

	override long getUserCount()
	{
		long count = 0;
		listDirectory(m_basePath ~ "user/", (de) {
			if (!de.name.endsWith(".json") || de.isDirectory) return true;
			count++;
			return true;
		});
		return count;
	}

	override void deleteUser(User.ID user_id)
	{
		auto usr = getUser(user_id);
		removeFile(userByEmailFile(usr.email));
		removeFile(userByNameFile(usr.name));
		removeFile(userFile(user_id));
	}

	override void updateUser(in ref User user)
	{

		enforce(existsFile(userFile(user.id)), "Invalid user ID.");
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");

		auto oldusr = getUser(user.id);
		auto oldemailfile = userByEmailFile(oldusr.email);
		auto newemailfile = userByEmailFile(user.email);
		auto oldnamefile = userByNameFile(oldusr.name);
		auto newnamefile = userByNameFile(user.name);

		if (existsFile(newemailfile)) {
			auto euid = User.ID.fromString(readFileUTF8(newemailfile).deserializeJson!string);
			enforce(euid == user.id, "E-mail address is already in use.");
		} else {
			moveFile(oldemailfile, newemailfile);
		}
		scope (failure) moveFile(newemailfile, oldemailfile);

		if (existsFile(newnamefile)) {
			auto euid = User.ID.fromString(readFileUTF8(newnamefile).deserializeJson!string);
			enforce(euid == user.id, "User name is already in use.");
		} else {
			moveFile(oldnamefile, newnamefile);
		}
		scope (failure) moveFile(newnamefile, oldnamefile);

		writeJsonFile(userFile(user.id), user);
	}

	override void setEmail(User.ID user, string email)
	{
		auto usr = getUser(user);
		usr.email = email;
		updateUser(usr);
	}

	override void setFullName(User.ID user, string full_name)
	{
		auto usr = getUser(user);
		usr.fullName = full_name;
		updateUser(usr);
	}

	override void setPassword(User.ID user, string password)
	{
		auto usr = getUser(user);
		usr.auth.method = "password";
		usr.auth.passwordHash = generatePasswordHash(password);
		updateUser(usr);
	}

	override void setProperty(User.ID user, string name, Json value)
	{
		auto usr = getUser(user);
		usr.properties[name] = value;
		updateUser(usr);
	}

	override void removeProperty(User.ID user, string name)
	{
		auto usr = getUser(user);
		usr.properties.remove(name);
		updateUser(usr);
	}

	override void addGroup(string id, string description)
	{
		enforce(isValidGroupID(id), "Invalid group ID.");
		enforce(!existsFile(groupFile(id)), "A group with this name already exists.");

		Group grp;
		grp.id = id;
		grp.description = description;
		writeJsonFile(groupFile(grp.id), grp);
	}

	override void removeGroup(string id)
	{
		removeFile(groupFile(id));
	}

	override void setGroupDescription(string name, string description)
	{
		auto grp = getGroup(name);
		grp.description = description;
		writeJsonFile(groupFile(name), grp);
	}

	override long getGroupCount()
	{
		long ret = 0;
		listDirectory(m_basePath ~ "group/", (de) {
			if (!de.name.endsWith(".json") || de.isDirectory) return true;
			ret++;
			return true;
		});
		return ret;
	}

	override Group getGroup(string id)
	{
		auto json = readFileUTF8(groupFile(id)).parseJsonString();
		// migration from 0.3.x to 0.4.x
		if (auto pn = "name" in json)
			if ("id" !in json)
				json["id"] = *pn;
		return deserializeJson!Group(json);
	}

	alias enumerateGroups = UserManController.enumerateGroups;
	override void enumerateGroups(long first_group, long max_count, scope void delegate(ref Group grp) @safe del)
	{
		listDirectory(m_basePath ~ "group/", (de) {
			if (!de.name.endsWith(".json") || de.isDirectory) return true;
			if (first_group > 0) {
				first_group--;
				return true;
			}
			if (max_count-- <= 0) return false;
			auto usr = getGroup(de.name[0 .. $-5]);
			del(usr);
			return true;
		});
	}

	override void addGroupMember(string group, User.ID user)
	{
		import std.algorithm : canFind;
		auto usr = getUser(user);
		if (!usr.groups.canFind(group))
			usr.groups ~= group;
		updateUser(usr);
	}

	override void removeGroupMember(string group, User.ID user)
	{
		import std.algorithm : countUntil;
		auto usr = getUser(user);
		auto idx = usr.groups.countUntil(group);
		if (idx >= 0) usr.groups = usr.groups[0 .. idx] ~ usr.groups[idx+1 .. $];
		updateUser(usr);
	}

	override long getGroupMemberCount(string group)
	{
		import std.algorithm : canFind;
		long ret = 0;
		enumerateUsers(0, long.max, (ref u) {
			if (u.groups.canFind(group))
				ret++;
		});
		return ret;
	}

	alias enumerateGroupMembers = UserManController.enumerateGroupMembers;
	override void enumerateGroupMembers(string group, long first_member, long max_count, scope void delegate(User.ID usr) @safe del)
	{
		import std.algorithm : canFind;
		long cnt = 0;
		enumerateUsers(0, long.max, (ref u) {
			if (!u.groups.canFind(group)) return;
			if (cnt++ < first_member) return;
			if (max_count-- <= 0) return;
			del(u.id);
		});
	}
}

private void writeJsonFile(T)(NativePath filename, T value)
{
	writeFileUTF8(filename, value.serializeToPrettyJson());
}

private T readJsonFile(T)(NativePath filename)
{
	import vibe.http.common : HTTPStatusException;
	import vibe.http.status : HTTPStatus;
	if (!existsFile(filename))
		throw new HTTPStatusException(HTTPStatus.notFound, "Database object does not exist ("~filename.toNativeString()~").");
	return readFileUTF8(filename).deserializeJson!T();
}
