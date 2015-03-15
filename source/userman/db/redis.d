/**
	Database abstraction layer

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: David Suppiger
*/
module userman.db.redis;

import userman.db.controller;

import vibe.db.redis.redis;
import vibe.db.redis.idioms;
import vibe.db.redis.types;
import vibe.data.bson;
import vibe.data.json;
import vibe.utils.validation;

import std.datetime;
import std.exception;
import std.string;
import std.conv;


class RedisUserManController : UserManController {
	private {
		RedisClient m_redisClient;
		RedisDatabase m_redisDB;

		RedisObjectCollection!(RedisStripped!User, RedisCollectionOptions.supportPaging) m_users;
		RedisObjectCollection!(AuthInfo, RedisCollectionOptions.none) m_userAuthInfo;
		RedisCollection!(RedisHash!string, RedisCollectionOptions.none) m_userProperties;
		RedisObjectCollection!(RedisStripped!Group, RedisCollectionOptions.supportPaging) m_groups;
		RedisCollection!(RedisHash!string, RedisCollectionOptions.none) m_groupProperties;
		//RedisCollection!(RedisSet!GroupMember, RedisCollectionOptions.none) m_groupMembers;

		// secondary indexes
		RedisHash!(long) m_usersByName;
		RedisHash!(long) m_usersByEmail;
		//RedisHash!(long) m_userGroups;
		RedisHash!long m_groupsByName;
	}
	
	this(UserManSettings settings)
	{	
		super(settings);

		string schema = "redis";
		auto idx = settings.databaseURL.indexOf("://");
		if (idx > 0)
			schema = settings.databaseURL[0..idx];

		enforce(schema == "redis", "databaseURL must be a redis connection string");

		// Parse string by replacing schema with 'http' as URL won't parse redis
		// URLs correctly.
		string url_string = settings.databaseURL;
		if (idx > 0) 
			url_string = url_string[idx+3..$];

		URL url = URL("http://" ~ url_string);
		url.schema = "redis";

		long dbIndex = 0;
		if (!url.path.empty)
			dbIndex = to!long(url.path.nodes[0].toString());

		m_redisClient = connectRedis(url.host, url.port == ushort.init ? 6379 : url.port);
		m_redisDB = m_redisClient.getDatabase(dbIndex);

		m_users = RedisObjectCollection!(RedisStripped!User, RedisCollectionOptions.supportPaging)(m_redisDB, "userman:user");
		m_userAuthInfo = RedisObjectCollection!(AuthInfo, RedisCollectionOptions.none)(m_redisDB, "userman:user", "auth");
		m_userProperties = RedisCollection!(RedisHash!string, RedisCollectionOptions.none)(m_redisDB, "userman:user", "properties");
		m_groups = RedisObjectCollection!(RedisStripped!Group, RedisCollectionOptions.supportPaging)(m_redisDB, "userman:group");
		m_groupProperties = RedisCollection!(RedisHash!string, RedisCollectionOptions.none)(m_redisDB, "userman:group", "properties");
		m_usersByName = RedisHash!long(m_redisDB, "userman:user:byName");
		m_usersByEmail = RedisHash!long(m_redisDB, "userman:user:byEmail");
		m_groupsByName = RedisHash!long(m_redisDB, "userman:group:byName");
	}

	override bool isEmailRegistered(string email)
	{
		auto uid = m_usersByEmail.get(email, -1);
		if (uid >= 0){
			string method = m_userAuthInfo[uid].method;
			return method != string.init && method.length > 0;
		}
		return false;
	}
	
	override User.ID addUser(ref User usr)
	{
		validateUser(usr);

		enforce(!m_usersByName.exists(usr.name), "The user name is already taken.");
		enforce(!m_usersByEmail.exists(usr.email), "The email address is already taken.");

		auto uid = m_users.createID();
		scope (failure) m_users.remove(uid);
		usr.id = User.ID(uid);

		// Indexes
		enforce(m_usersByEmail.setIfNotExist(usr.email, uid), "Failed to associate new user with e-mail address.");
		scope (failure) m_usersByEmail.remove(usr.email);
		enforce(m_usersByName.setIfNotExist(usr.name, uid), "Failed to associate new user with user name.");
		scope (failure) m_usersByName.remove(usr.name);

		// User
		m_users[uid] = usr.redisStrip();

		// Credentials
		m_userAuthInfo[uid] = usr.auth;

		// Properties
		auto props = m_userProperties[uid];
		foreach (string name, value; usr.properties)
			props[name] = value.toString();

		// Group membership
		foreach(Group.ID gid; usr.groups)
			m_redisDB.sadd("userman:group:" ~ gid ~ ":members", uid);

		return usr.id;
	}

	override User getUser(User.ID id)
	{
		auto susr = m_users[id.longValue];
		enforce(susr.exists, "The specified user id is invalid.");

		// Group membership
		// TODO: avoid going over all (potentially large number of) groups
		Group.ID[] groups;
		foreach (gid, grp; m_groups)
			if (m_redisDB.sisMember("userman:group:" ~ gid.to!string ~ ":members", id))
				groups ~= Group.ID(gid);

		// Credentials
		auto auth = m_userAuthInfo[id.longValue];

		// Properties
		Json[string] properties;
		foreach(string name, string value; m_userProperties[id.longValue])
			properties[name] = parseJsonString(value);

		return susr.unstrip(id, groups, auth, properties);
	}

	override User getUserByName(string name)
	{
		name = name.toLower();

		User.ID userId = m_usersByName.get(name, -1);
		try return getUser(userId);
		catch (Exception e) {
			throw new Exception("The specified user name is not registered.");
		}
	}

	override User getUserByEmail(string email)
	{
		email = email.toLower();

		User.ID uid = m_usersByEmail.get(email, -1);
		try return getUser(uid);
		catch (Exception e) {
			throw new Exception("There is no user account for the specified email address.");
		}
	}

	override User getUserByEmailOrName(string email_or_name)
	{
		long uid = m_usersByEmail.get(email_or_name, -1);
		if (uid < 0) uid = m_usersByName.get(email_or_name, -1);

		try return getUser(User.ID(uid));
		catch (Exception e) {
			throw new Exception("The specified email address or user name is not registered.");
		}
	}

	override void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del)
	{
		foreach (userId; m_redisDB.zrange!string("userman:user:all", first_user, first_user + max_count)) {
			auto usr = getUser(User.ID(userId.to!long));
			del(usr);
		}
	}

	override long getUserCount()
	{
		return m_redisDB.zcard("userman:user:all");
	}

	override void deleteUser(User.ID user_id)
	{
		User usr = getUser(user_id);

		// Indexes
		m_users.remove(user_id.longValue);
		m_usersByEmail.remove(usr.email);
		m_usersByName.remove(usr.name);

		// Credentials
		m_userAuthInfo.remove(user_id.longValue);

		// Properties
		m_userProperties[user_id.longValue].value.remove();

		// Group membership
		foreach(Group.ID gid; usr.groups)
			m_redisDB.srem("userman:group:" ~ gid ~ ":members", user_id);
	}

	override void updateUser(in ref User user)
	{
		enforce(m_users.isMember(user.id.longValue), "Invalid user ID.");
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");

		auto exeid = m_usersByEmail.get(user.email, -1);
		enforce(exeid < 0 || exeid == user.id.longValue,
			"E-mail address is already in use.");
		enforce(exeid == user.id.longValue || m_usersByEmail.setIfNotExist(user.email, user.id.longValue),
			"Failed to associate new e-mail address to user.");
		scope (failure) m_usersByEmail.remove(user.email);

		auto exnid = m_usersByName.get(user.name, -1);
		enforce(exnid < 0 || exnid == user.id.longValue,
			"User name address is already in use.");
		enforce(exnid == user.id.longValue || m_usersByName.setIfNotExist(user.name, user.id.longValue),
			"Failed to associate new user name to user.");
		scope (failure) m_usersByEmail.remove(user.name);


		// User
		m_users[user.id.longValue] = user.redisStrip();

		// Credentials
		m_userAuthInfo[user.id.longValue] = user.auth;

		// Properties
		auto props = m_userProperties[user.id.longValue];
		props.value.remove();
		foreach (string name, value; user.properties)
			props[name] = value.toString();

		// Group membership
		foreach (gid, grp; m_groups) {
			if (user.isInGroup(Group.ID(gid)))
				m_redisDB.sadd("userman:group:" ~ gid.to!string ~ ":members", user.id);
			else
				m_redisDB.srem("userman:group:" ~ gid.to!string ~ ":members", user.id);
		}
	}
	
	override void setEmail(User.ID user, string email)
	{
		validateEmail(email);
		enforce(m_users.isMember(user.longValue), "Invalid user ID.");

		auto exid = m_usersByEmail.get(email, -1);
		enforce(exid < 0 || exid == user.longValue,
			"E-mail address is already in use.");
		enforce(exid == user.longValue || m_usersByEmail.setIfNotExist(email, user.longValue),
			"Failed to associate new e-mail address to user.");

		m_users[user.longValue].email = email;
	}

	override void setFullName(User.ID user, string full_name)
	{
		enforce(m_users.isMember(user.longValue), "Invalid user ID.");
		m_users[user.longValue].fullName = full_name;
	}
	
	override void setPassword(User.ID user, string password)
	{
		import vibe.crypto.passwordhash;

		enforce(m_users.isMember(user.longValue), "Invalid user ID.");

		AuthInfo auth = m_userAuthInfo[user.longValue];
		auth.method = "password";
		auth.passwordHash = generateSimplePasswordHash(password);
		m_userAuthInfo[user.longValue] = auth;
	}
	
	override void setProperty(User.ID user, string name, string value)
	{
		enforce(m_users.isMember(user.longValue), "Invalid user ID.");

		m_userProperties[user.longValue][name] = Bson(value).toString();
	}
	
	override void addGroup(string name, string description)
	{
		// TODO: avoid iterating over all groups!
		foreach (id, grp; m_groups) {
			enforce(grp.name != name, "A group with this name already exists.");
		}

		// Add Group
		long groupId = m_groups.createID();
		Group grp = {
			id: Group.ID(groupId), 
			name: name, 
			description: description
		};

		m_groups[groupId] = grp.redisStrip();
		foreach (k, v; grp.properties)
			m_groupProperties[groupId][k] = v.toString();

		m_groupsByName[name] = groupId;
	}

	override Group getGroup(Group.ID id)
	{
		auto sgrp = m_groups[id.longValue];
		enforce(sgrp.exists, "The specified group id is invalid.");

		// Properties
		Json[string] properties;
		foreach(string name, string value; m_groupProperties[id.longValue])
			properties[name] = parseJsonString(value);

		return sgrp.unstrip(id, properties);
	}

	override Group getGroupByName(string name)
	{
		auto grpid = m_groupsByName.get(name, -1);
		enforce(grpid != -1, "The specified group name is unknown.");
		return getGroup(Group.ID(grpid));
	}
}
