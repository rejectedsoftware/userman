/**
 * Group data structure for the web part of Userman
 */
module userman.web.group;

import userman.id;
import vibe.data.json;

struct Group {
	alias .ID!Group ID;
	@(.name("_id")) ID id;

	string name;
	string description;
	@optional Json[string] properties;
}
