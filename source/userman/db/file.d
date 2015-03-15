/**
	File system based database controller.

	Copyright: 2015 RejectedSoftware e.K.
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
		Path m_basePath;
	}
	
	this(UserManSettings settings)
	{	
		super(settings);

		enforce(settings.databaseURL.startsWith("file://"),
			"Database URL must have a file:// schema.");

		m_basePath = URL(settings.databaseURL).path;
		string[] paths = [".", "user", "user/byName", "user/byEmail", "group", "group/byName"];
		foreach (p; paths)
			if (!existsFile(m_basePath ~ p))
				createDirectory(m_basePath ~ p);
	}

	override bool isEmailRegistered(string email)
	{
		return existsFile(userByEmailFile(email));
	}

	private final Path userByNameFile(string name) { return m_basePath ~ "user/byName/" ~ (urlEncode(name) ~ ".json"); }
	private final Path userByEmailFile(string email) { return m_basePath ~ "user/byEmail/" ~ (urlEncode(email) ~ ".json"); }
	private final Path userFile(User.ID id) { return m_basePath ~ "user/" ~ (id.toString() ~ ".json"); }
	private final Path groupByNameFile(string name) { return m_basePath ~ "group/byName/" ~ (urlEncode(name) ~ ".json"); }
	private final Path groupFile(Group.ID id) { return m_basePath ~ "group/" ~ (id.toString() ~ ".json"); }
	
	override User.ID addUser(ref User usr)
	{
		validateUser(usr);
		enforce(!isEmailRegistered(usr.email), "The email address is already taken.");
		enforce(!existsFile(userByNameFile(usr.name)), "The user name is already taken.");

		usr.id = User.ID(randomUUID());
		if (usr.resetCodeExpireTime == SysTime.init)
			usr.resetCodeExpireTime = SysTime(0);

		// Indexes
		writeFileUTF8(userByEmailFile(usr.email), Json(usr.id).toString());
		scope (failure) removeFile(userByEmailFile(usr.email));
		writeFileUTF8(userByNameFile(usr.name), Json(usr.id).toString());
		scope (failure) removeFile(userByNameFile(usr.name));

		writeFileUTF8(userFile(usr.id), serializeToPrettyJson(usr));

		return usr.id;
	}

	override User getUser(User.ID id)
	{
		return deserializeJson!User(readFileUTF8(userFile(id)));
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

	override void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del)
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

		writeFileUTF8(userFile(user.id), serializeToPrettyJson(user));
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
		import vibe.crypto.passwordhash;

		auto usr = getUser(user);
		usr.auth.method = "password";
		usr.auth.passwordHash = generateSimplePasswordHash(password);
		updateUser(usr);
	}
	
	override void setProperty(User.ID user, string name, string value)
	{
		auto usr = getUser(user);
		usr.properties[name] = value;
		updateUser(usr);
	}
	
	override void addGroup(string name, string description)
	{
		enforce(!existsFile(groupByNameFile(name)), "A group with this name already exists.");

		Group grp;
		grp.id = Group.ID(randomUUID);
		grp.name = name;
		grp.description = description;
		writeFileUTF8(groupFile(grp.id), serializeToJsonString(grp));
		writeFileUTF8(groupByNameFile(grp.name), serializeToJsonString(grp.id.toString()));
	}

	override Group getGroup(Group.ID id)
	{
		return readFileUTF8(groupFile(id)).deserializeJson!Group;
	}

	override Group getGroupByName(string name)
	{
		return getGroup(readFileUTF8(groupByNameFile(name)).deserializeJson!(Group.ID));
	}
}

