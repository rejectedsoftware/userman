/**
	Database abstraction layer

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: David Suppiger
*/
module userman.rediscontroller;

import userman.controller;

import vibe.db.redis.redis;
import vibe.db.redis.idioms;
import vibe.db.redis.types;
import vibe.data.bson;
import vibe.data.json;

import std.datetime;
import std.exception;
import std.string;
import std.conv;


class RedisUserManController : UserManController {
	private {
		RedisClient m_redisClient;
		RedisDatabase m_redisDB;

		//RedisObjectCollection!(RedisStripped!User, RedisCollectionOptions.none) m_users;
		RedisObjectCollection!(AuthInfo, RedisCollectionOptions.none) m_authInfos;
		RedisCollection!(RedisHash!string, RedisCollectionOptions.none) m_properties;
		RedisObjectCollection!(RedisStripped!Group, RedisCollectionOptions.supportPaging) m_groups;
		RedisCollection!(RedisHash!string, RedisCollectionOptions.none) m_groupProperties;

		// secondary indexes
		RedisHash!(long) m_usersByName;
		RedisHash!(long) m_usersByEmail;
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

		//m_users = RedisObjectCollection!(RedisStripped!User, RedisCollectionOptions.supportPaging)(m_redisDB, "userman:user");
		m_authInfos = RedisObjectCollection!(AuthInfo, RedisCollectionOptions.none)(m_redisDB, "userman:user", "auth");
		m_properties = RedisCollection!(RedisHash!string, RedisCollectionOptions.none)(m_redisDB, "userman:user", "properties");
		m_groups = RedisObjectCollection!(RedisStripped!Group, RedisCollectionOptions.supportPaging)(m_redisDB, "userman:group");
		m_groupProperties = RedisCollection!(RedisHash!string, RedisCollectionOptions.none)(m_redisDB, "userman:group", "properties");
		m_usersByName = RedisHash!long(m_redisDB, "userman:user:byName");
		m_usersByEmail = RedisHash!long(m_redisDB, "userman:user:byEmail");
	}

	override bool isEmailRegistered(string email)
	{
		auto uid = m_usersByEmail.get(email, -1);
		if (uid >= 0){
			string method = m_authInfos[uid].method;
			return method != string.init && method.length > 0;
		}
		return false;
	}
	
	override User.ID addUser(ref User usr)
	{
		validateUser(usr);

		enforce(!m_usersByName.exists(usr.name), "The user name is already taken.");
		enforce(!m_usersByEmail.exists(usr.email), "The email address is already taken.");

		long uid = m_redisDB.incr("userman:user:max");
		m_redisDB.zadd("userman:user:all", uid, uid);
		usr.id = User.ID(uid);

		// Indexes
		m_usersByEmail[usr.email] = uid;
		m_usersByName[usr.name] = uid;

		// User
		m_redisDB.hmset(format("userman:user:%s", uid), 
						"active", to!string(usr.active), 
						"banned", to!string(usr.banned), 
						"name", usr.name, 
						"fullName", usr.fullName, 
						"email", usr.email, 
						"activationCode", usr.activationCode,
						"resetCode", usr.resetCode,
						"resetCodeExpireTime", usr.resetCodeExpireTime == SysTime() ? "" : usr.resetCodeExpireTime.toISOExtString());

		// Credentials
		m_authInfos[uid] = usr.auth;

		// Properties
		auto props = m_properties[uid];
		foreach (string name, value; usr.properties)
			props[name] = value.toString();

		// Group membership
		foreach(Group.ID gid; usr.groups)
			m_redisDB.sadd("userman:group:" ~ gid ~ ":members", uid);

		return usr.id;
	}

	override User getUser(User.ID id)
	{
		auto userHash = m_redisDB.hgetAll("userman:user:" ~ id);
		enforce(userHash.hasNext(), "The specified user id is invalid.");

		User ret;

		// User
		ret.id = id;
		while (userHash.hasNext()) {
		 	string key = userHash.next!string();
		 	string value = userHash.next!string();
		 	switch (key)
		 	{
		 		case "active": ret.active = to!bool(value); break;
		 		case "banned": ret.banned = to!bool(value); break;
		 		case "name": ret.name = value; break;
		 		case "fullName": ret.fullName = value; break;
		 		case "email": ret.email = value; break;
		 		case "activationCode": ret.activationCode = value; break;
		 		case "resetCode": ret.resetCode = value; break;
		 		case "resetCodeExpireTime":
		 			try {
		 				ret.resetCodeExpireTime = SysTime.fromISOExtString(value);
	 				} catch (DateTimeException dte) {}
	 				break;
		 		default: break;
		 	}
		}

		// Credentials
		ret.auth = m_authInfos[id.longValue];

		// Properties
		auto props = m_properties[id.longValue];
		foreach(string name, string value; props)
			ret.properties[name] = parseJsonString(value);

		// Group membership
		foreach (gid, grp; m_groups) {
			if (m_redisDB.sisMember("userman:group:" ~ gid.to!string ~ ":members", id))
			{
				++ret.groups.length;
				ret.groups[ret.groups.length - 1] = gid;
			}
		}

		return ret;
	}

	override User getUserByName(string name)
	{
		name = name.toLower();

		User.ID userId = m_redisDB.get!string("userman:name_user:" ~ name).to!long;
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
		m_redisDB.zrem("userman:user:all", user_id);
		m_usersByEmail.remove(usr.email);
		m_usersByName.remove(usr.name);

		// User
		m_redisDB.del(format("userman:user:%s", user_id));

		// Credentials
		m_authInfos.remove(user_id.longValue);

		// Properties
		m_properties[user_id.longValue].value.remove();

		// Group membership
		foreach(Group.ID gid; usr.groups)
			m_redisDB.srem("userman:group:" ~ gid ~ ":members", user_id);
	}

	override void updateUser(in ref User user)
	{
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");

		// User
		m_redisDB.hmset(format("userman:user:%s", user.id.longValue), 
						"active", to!string(user.active), 
						"banned", to!string(user.banned), 
						"name", user.name, 
						"fullName", user.fullName, 
						"email", user.email, 
						"activationCode", user.activationCode,
						"resetCode", user.resetCode,
						"resetCodeExpireTime", user.resetCodeExpireTime == SysTime() ? "" : user.resetCodeExpireTime.toISOExtString());

		// Credentials
		m_authInfos[user.id.longValue] = user.auth;

		// Properties
		auto props = m_properties[user.id.longValue];
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

		// FIXME: update m_usersByEmail and m_usersByName
	}
	
	override void setEmail(User.ID user, string email)
	{
		string key = format("userman:user:%s", user.longValue);
		if (m_redisDB.exists(key))
			m_redisDB.hset!string(key, "email", email);

		// FIXME: update m_usersByEmail
	}

	override void setFullName(User.ID user, string full_name)
	{
		string key = format("userman:user:%s", user.longValue);
		if (m_redisDB.exists(key))
			m_redisDB.hset!string(key, "fullName", full_name);
	}
	
	override void setPassword(User.ID user, string password)
	{
		if (m_redisDB.exists(format("userman:user:%s", user.longValue))) {
			import vibe.crypto.passwordhash;
			AuthInfo auth = m_authInfos[user.longValue];
			auth.method = "password";
			auth.passwordHash = generateSimplePasswordHash(password);
			m_authInfos[user.longValue] = auth;
		}
	}
	
	override void setProperty(User.ID user, string name, string value)
	{
		if (m_redisDB.exists(format("userman:user:%s", user.longValue)))
			m_properties[user.longValue][name] = Bson(value).toString();
	}
	
	override void addGroup(string name, string description)
	{
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
	}
}
