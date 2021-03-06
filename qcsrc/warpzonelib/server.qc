.vector warpzone_oldorigin, warpzone_oldvelocity, warpzone_oldangles;
.float warpzone_teleport_time;
.float warpzone_teleport_finishtime;
.entity warpzone_teleport_zone;

void WarpZone_StoreProjectileData(entity e)
{
	e.warpzone_oldorigin = e.origin;
	e.warpzone_oldvelocity = e.velocity;
	e.warpzone_oldangles = e.angles;
}

void WarpZone_TeleportPlayer(entity teleporter, entity player, vector to, vector to_angles, vector to_velocity)
{
	vector from;

	makevectors (to_angles);

	from = player.origin;
	setorigin (player, to);
	player.oldorigin = to; // for DP's unsticking
	player.angles = to_angles;
	player.v_angle = to_angles;
	player.fixangle = TRUE;
	player.velocity = to_velocity;

	if(player.effects & EF_TELEPORT_BIT)
		player.effects &~= EF_TELEPORT_BIT;
	else
		player.effects |= EF_TELEPORT_BIT;

	if(player.classname == "player")
		player.flags &~= FL_ONGROUND;

	WarpZone_PostTeleportPlayer_Callback(player, teleporter);
}

float WarpZone_Teleported_Send(entity to, float sf)
{
	WriteByte(MSG_ENTITY, ENT_CLIENT_WARPZONE_TELEPORTED);
	WriteCoord(MSG_ENTITY, self.angles_x);
	WriteCoord(MSG_ENTITY, self.angles_y);
	WriteCoord(MSG_ENTITY, self.angles_z);
	return TRUE;
}

float WarpZone_Teleport(entity wz, entity player, float f0, float f1)
{
	vector o0, a0, v0, o1, a1, v1, o10;

	o0 = player.origin + player.view_ofs;
	v0 = player.velocity;
	a0 = player.angles;

	o10 = o1 = WarpZone_TransformOrigin(wz, o0);
	v1 = WarpZone_TransformVelocity(wz, v0);
	if not(clienttype(player) == CLIENTTYPE_NOTACLIENT)
		a1 = WarpZone_TransformVAngles(wz, player.v_angle);
	else
		a1 = WarpZone_TransformAngles(wz, a0);

	if(f0 != 0 || f1 != 0)
	{
		// retry last move but behind the warpzone!
		// we must first go back as far as we can, then forward again, to not cause double touch events!

		tracebox(o1 - player.view_ofs + v1 * frametime * f1, player.mins, player.maxs, o1 - player.view_ofs + v1 * frametime * f0, MOVE_WORLDONLY, player);
		{
			entity own;
			own = player.owner;
			player.owner = world;
			tracebox(trace_endpos, player.mins, player.maxs, o1 - player.view_ofs + v1 * frametime * f1, MOVE_NORMAL, player); // this should get us through the warpzone
			player.owner = own;
		}
		o1 = trace_endpos + player.view_ofs;

		float d, dv, md;
		md = max(vlen(player.mins), vlen(player.maxs));
		d = WarpZone_TargetPlaneDist(wz, o1);
		dv = WarpZone_TargetPlaneDist(wz, v1);
		if(d < 0)
			o1 = o1 - v1 * (d / dv);
	}

	// put him out of solid
    if(player.movetype != MOVETYPE_NOCLIP) {
        tracebox(o1 - player.view_ofs, player.mins, player.maxs, o1 - player.view_ofs, MOVE_NOMONSTERS, player);
        if(trace_startsolid)
        {
            setorigin(player, o1 - player.view_ofs);
            if(WarpZoneLib_MoveOutOfSolid(player))
            {
                o1 = player.origin + player.view_ofs;
                setorigin(player, o0 - player.view_ofs);
            }
            else
            {
                print("would have to put player in solid, won't do that\n");
                setorigin(player, o0 - player.view_ofs);
                return 0;
            }
        }
    }

	// do the teleport
	WarpZone_RefSys_Add(player, wz);
	WarpZone_TeleportPlayer(wz, player, o1 - player.view_ofs, a1, v1);
	WarpZone_StoreProjectileData(player);
	player.warpzone_teleport_time = time;
	player.warpzone_teleport_finishtime = time;
	player.warpzone_teleport_zone = wz;

	// prevent further teleports back
	float dt = (o1 - o10) * v1 * (1 / (v1 * v1));
	if(dt < frametime)
		player.warpzone_teleport_finishtime += frametime - dt;

#ifndef WARPZONE_USE_FIXANGLE
	if(player.classname == STR_PLAYER)
	{
		// instead of fixangle, send the transform to the client for smoother operation
		player.fixangle = FALSE;

		entity ts = spawn();
		setmodel(ts, "null");
		ts.SendEntity = WarpZone_Teleported_Send;
		ts.SendFlags = 0xFFFFFF;
		ts.think = SUB_Remove;
		ts.nextthink = time + 1;
		ts.owner = player;
		ts.enemy = wz;
		ts.effects = EF_NODEPTHTEST;
		ts.classname = "warpzone_teleported";
		ts.angles = wz.warpzone_transform;
        ts.customizeentityforclient = inline float(void) {
            if(other == self.owner)
                return TRUE;

            if(other.enemy == self.owner && other.classname == "spectator")
                return TRUE;

            return FALSE;
        };
	}
#endif

	return 1;
}

void WarpZone_Touch (void)
{
	entity oldself;

	if(other.classname == "trigger_warpzone")
		return;

	if(time <= other.warpzone_teleport_finishtime) // already teleported this frame
		return;

	// FIXME needs a better check to know what is safe to teleport and what not
	if(other.movetype == MOVETYPE_NONE || other.movetype == MOVETYPE_FOLLOW || other.tag_entity)
		return;

	if(WarpZoneLib_ExactTrigger_Touch())
		return;

	if(WarpZone_PlaneDist(self, other.origin + other.view_ofs) >= 0) // wrong side of the trigger_warpzone (don't teleport yet)
		return;

	float f;
	// number of frames we need to go back:
	//   dist = 16*sqrt(2) qu
	//   dist ~ 24 qu
	//   24 qu = v*t
	//   24 qu = v*frametime*n
	//       n = 24 qu/(v*frametime)
	// for clients go only one frame though, may be too irritating otherwise
	// but max 0.25 sec = 0.25/frametime frames
	//       24/(0.25/frametime)
	//       96*frametime
	float d;
	d = 24 + max(vlen(other.mins), vlen(other.maxs));
	if(clienttype(other) == CLIENTTYPE_NOTACLIENT)
		f = -d / bound(frametime * d * 1, frametime * vlen(other.velocity), d);
	else
		f = -1;

    if(other.classname == "observer") {
        WarpZone_Teleport(self, other, f, 0);
        return;
    }

	if(WarpZone_Teleport(self, other, f, 0))
	{
		string save1, save2;
		activator = other;

		save1 = self.target; self.target = NULL;
		save2 = self.target3; self.target3 = NULL;
		SUB_UseTargets();
		if not(self.target) self.target = save1;
		if not(self.target3) self.target3 = save2;

		oldself = self;
		self = self.enemy;
		save1 = self.target; self.target = NULL;
		save2 = self.target2; self.target2 = NULL;
		SUB_UseTargets();
		if not(self.target) self.target = save1;
		if not(self.target2) self.target2 = save2;
		self = oldself;
	}
	else
	{
		dprint("WARPZONE FAIL AHAHAHAHAH))\n");
	}
}

float WarpZone_Send(entity to, float sendflags)
{
	WriteByte(MSG_ENTITY, ENT_CLIENT_WARPZONE);

	// we need THESE to render the warpzone (and cull properly)...
	WriteCoord(MSG_ENTITY, self.origin_x);
	WriteCoord(MSG_ENTITY, self.origin_y);
	WriteCoord(MSG_ENTITY, self.origin_z);

	WriteShort(MSG_ENTITY, self.modelindex);
	WriteCoord(MSG_ENTITY, self.mins_x);
	WriteCoord(MSG_ENTITY, self.mins_y);
	WriteCoord(MSG_ENTITY, self.mins_z);
	WriteCoord(MSG_ENTITY, self.maxs_x);
	WriteCoord(MSG_ENTITY, self.maxs_y);
	WriteCoord(MSG_ENTITY, self.maxs_z);
	WriteByte(MSG_ENTITY, bound(1, self.scale * 16, 255));

	// we need THESE to calculate the proper transform
	WriteCoord(MSG_ENTITY, self.warpzone_origin_x);
	WriteCoord(MSG_ENTITY, self.warpzone_origin_y);
	WriteCoord(MSG_ENTITY, self.warpzone_origin_z);
	WriteCoord(MSG_ENTITY, self.warpzone_angles_x);
	WriteCoord(MSG_ENTITY, self.warpzone_angles_y);
	WriteCoord(MSG_ENTITY, self.warpzone_angles_z);
	WriteCoord(MSG_ENTITY, self.warpzone_targetorigin_x);
	WriteCoord(MSG_ENTITY, self.warpzone_targetorigin_y);
	WriteCoord(MSG_ENTITY, self.warpzone_targetorigin_z);
	WriteCoord(MSG_ENTITY, self.warpzone_targetangles_x);
	WriteCoord(MSG_ENTITY, self.warpzone_targetangles_y);
	WriteCoord(MSG_ENTITY, self.warpzone_targetangles_z);

	return TRUE;
}

float WarpZone_Camera_Send(entity to, float sendflags)
{
	WriteByte(MSG_ENTITY, ENT_CLIENT_WARPZONE_CAMERA);

	// we need THESE to render the warpzone (and cull properly)...
	WriteCoord(MSG_ENTITY, self.origin_x);
	WriteCoord(MSG_ENTITY, self.origin_y);
	WriteCoord(MSG_ENTITY, self.origin_z);

	WriteShort(MSG_ENTITY, self.modelindex);
	WriteCoord(MSG_ENTITY, self.mins_x);
	WriteCoord(MSG_ENTITY, self.mins_y);
	WriteCoord(MSG_ENTITY, self.mins_z);
	WriteCoord(MSG_ENTITY, self.maxs_x);
	WriteCoord(MSG_ENTITY, self.maxs_y);
	WriteCoord(MSG_ENTITY, self.maxs_z);
	WriteByte(MSG_ENTITY, bound(1, self.scale * 16, 255));

	// we need THESE to calculate the proper transform
	WriteCoord(MSG_ENTITY, self.enemy.origin_x);
	WriteCoord(MSG_ENTITY, self.enemy.origin_y);
	WriteCoord(MSG_ENTITY, self.enemy.origin_z);
	WriteCoord(MSG_ENTITY, self.enemy.angles_x);
	WriteCoord(MSG_ENTITY, self.enemy.angles_y);
	WriteCoord(MSG_ENTITY, self.enemy.angles_z);

	return TRUE;
}

float WarpZone_CheckProjectileImpact()
{
	// if self hit a warpzone, abort
	vector o0, v0, a0;
	float mpd, pd, dpd;
	entity wz;

    save_trace_globals();
	wz = WarpZone_Find(self.origin + self.mins, self.origin + self.maxs);
    restore_trace_globals();

	if(!wz)
		return FALSE;

	o0 = self.origin;
	v0 = self.velocity;
	a0 = self.angles;

	// this approach transports the projectile at its full speed, but does
	// not properly retain the projectile trail (but we can't retain it
	// easily anyway without delaying the projectile by two frames, so who
	// cares)
	WarpZone_TraceBox_ThroughZone(self.warpzone_oldorigin, self.mins, self.maxs, self.warpzone_oldorigin + self.warpzone_oldvelocity * frametime, MOVE_NORMAL, self, wz, NULL); // this will get us through the warpzone
	setorigin(self, trace_endpos);
	self.angles = WarpZone_TransformAngles(WarpZone_trace_transform, self.angles);
	self.velocity = WarpZone_TransformVelocity(WarpZone_trace_transform, self.velocity);
	if (trace_fraction < 1) //We hit something right behind warp
		return FALSE;
	
	// in case we are in our warp zone post-teleport, shift the projectile forward a bit
	mpd = max(vlen(self.mins), vlen(self.maxs));
	pd = WarpZone_TargetPlaneDist(wz, self.origin);
	if(pd < mpd)
	{
		dpd = normalize(self.velocity) * self.warpzone_targetforward;
		setorigin(self, self.origin + normalize(self.velocity) * ((mpd - pd) / dpd));
		if(!WarpZoneLib_MoveOutOfSolid(self))
		{
			setorigin(self, o0);
			self.angles = a0;
			self.velocity = v0;
			return FALSE;
		}
	}
	WarpZone_RefSys_Add(self, wz);
	WarpZone_StoreProjectileData(self);
	self.warpzone_teleport_time = time;

	return TRUE;
}
float WarpZone_Projectile_Touch()
{
	if(other.classname == "trigger_warpzone")
		return TRUE;
	if(WarpZone_CheckProjectileImpact())
		return TRUE;
	if(self.warpzone_teleport_time == time) // already got teleported this frame? no collision then please
	{
		setorigin(self, self.warpzone_oldorigin);
		self.velocity = self.warpzone_oldvelocity;
		self.angles = self.warpzone_oldangles;
		return TRUE;
	}

	return FALSE;
}

void WarpZone_InitStep_FindTarget()
{
	entity e;

	if(self.killtarget != "")
	{
		self.aiment = find(world, targetname, self.killtarget);
		if(self.aiment == world)
		{
			error("Warp zone with nonexisting killtarget");
			return;
		}
	}

	// this way only one of the two ents needs to target
	if(self.target != "")
	{
		e = find(world, targetname, self.target);
		if(e)
		{
			self.enemy = e;
			self.enemy.enemy = self;
		}
	}
}

void WarpZonePosition_InitStep_FindTarget()
{
	if(self.target == "")
	{
		error("Warp zone position with no target");
		return;
	}
	self.enemy = find(world, targetname, self.target);
	if(self.enemy == world)
	{
		error("Warp zone position with nonexisting target");
		return;
	}
	if(self.enemy.aiment)
	{
		// already is positioned
		error("Warp zone position targeting already oriented warpzone");
		return;
	}
	self.enemy.aiment = self;
}

void WarpZoneCamera_InitStep_FindTarget()
{
	if(self.target == "")
	{
		error("Camera with no target");
		return;
	}
	self.enemy = find(world, targetname, self.target);
	if(self.enemy == world)
	{
		error("Camera with nonexisting target");
		return;
	}
}

void WarpZone_InitStep_UpdateTransform()
{
	vector org, ang, norm, point;
	float area;
	vector tri, a, b, c, p, q, n;
	float i_s, i_t, n_t;
	string tex;

	if(!self.enemy || self.enemy.enemy != self)
	{
		error("Invalid warp zone detected. Killed.");
		return;
	}

	org = self.origin;
	if(org == '0 0 0')
		org = 0.5 * (self.mins + self.maxs);

	norm = point = '0 0 0';
	area = 0;
	for(i_s = 0; ; ++i_s)
	{
		tex = getsurfacetexture(self, i_s);
		if not(tex)
			break; // this is beyond the last one
		if(tex == "texture/common/trigger")
			continue;
		n_t = getsurfacenumtriangles(self, i_s);
		for(i_t = 0; i_t < n_t; ++i_t)
		{
			tri = getsurfacetriangle(self, i_s, i_t);
			a = getsurfacepoint(self, i_s, tri_x);
			b = getsurfacepoint(self, i_s, tri_y);
			c = getsurfacepoint(self, i_s, tri_z);
			p = b - a;
			q = c - a;
			n =     '1 0 0' * (q_y * p_z - q_z * p_y)
			+       '0 1 0' * (q_z * p_x - q_x * p_z)
			+       '0 0 1' * (q_x * p_y - q_y * p_x);
			area = area + vlen(n);
			norm = norm + n;
			point = point + vlen(n) * (a + b + c);
		}
	}
	if(area > 0)
	{
		norm = norm * (1 / area);
		point = point * (1 / (3 * area));
		if(vlen(norm) < 0.99)
		{
			print("trigger_warpzone near ", vtos(self.aiment.origin), " is nonplanar. BEWARE.\n");
			area = 0; // no autofixing in this case
		}
		norm = normalize(norm);
	}

	if(self.aiment)
	{
		org = self.aiment.origin;
		ang = self.aiment.angles;
		if(area > 0)
		{
			org = org - ((org - point) * norm) * norm; // project to plane
			makevectors(ang);
			if(norm * v_forward < 0)
			{
				print("Position target of trigger_warpzone near ", vtos(self.aiment.origin), " points into trigger_warpzone. BEWARE.\n");
				norm = -1 * norm;
			}
			ang = vectoangles(norm, v_up); // keep rotation, but turn exactly against plane
			ang_x = -ang_x;
			if(norm * v_forward < 0.99)
				print("trigger_warpzone near ", vtos(self.aiment.origin), " has been turned to match plane orientation (", vtos(self.aiment.angles), " -> ", vtos(ang), "\n");
			if(vlen(org - self.aiment.origin) > 0.5)
				print("trigger_warpzone near ", vtos(self.aiment.origin), " has been moved to match the plane (", vtos(self.aiment.origin), " -> ", vtos(org), ").\n");
		}
	}
	else if(area > 0)
	{
		org = point;
		ang = vectoangles(norm);
		ang_x = -ang_x;
	}
	else
		error("cannot infer origin/angles for this warpzone, please use a killtarget or a trigger_warpzone_position");

	self.warpzone_origin = org;
	self.warpzone_angles = ang;
}
void WarpZone_InitStep_FinalizeTransform()
{
	WarpZone_SetUp(self, self.warpzone_origin, self.warpzone_angles, self.enemy.warpzone_origin, self.enemy.warpzone_angles);
	self.touch = WarpZone_Touch;
}

float warpzone_initialized;
entity warpzone_first;
entity warpzone_position_first;
entity warpzone_camera_first;
.entity warpzone_next;

float warpzone_maybe_remove(void) {
    if(CVAR(sv_nowarpzones)) {
        remove(self);
        return TRUE;
    }

    return FALSE;
}

void spawnfunc_misc_warpzone_position(void)
{
    if(warpzone_maybe_remove())
        return;

	// "target", "angles", "origin"
	self.warpzone_next = warpzone_position_first;
	warpzone_position_first = self;
}
void spawnfunc_trigger_warpzone_position(void)
{
	spawnfunc_misc_warpzone_position();
}
void spawnfunc_trigger_warpzone(void)
{
    if(warpzone_maybe_remove())
        return;

	// warp zone entities must have:
	// "killtarget" pointing to a target_position with a direction arrow
	//              that points AWAY from the warp zone, and that is inside
	//              the warp zone trigger
	// "target"     pointing to an identical warp zone at another place in
	//              the map, with another killtarget to designate its
	//              orientation

	if(!self.scale)
		self.scale = self.modelscale;
	if(!self.scale)
		self.scale = 1;
	string m;
	m = self.model;
	WarpZoneLib_ExactTrigger_Init();
 	if(m != "")
 	{
 		precache_model(m);
 		setmodel(self, m); // no precision needed
	}
	setorigin(self, self.origin);
	if(self.scale)
		setsize(self, self.mins * self.scale, self.maxs * self.scale);
	else
		setsize(self, self.mins, self.maxs);
	self.SendEntity = WarpZone_Send;
	self.SendFlags = 0xFFFFFF;
	self.effects |= EF_NODEPTHTEST;
	self.warpzone_next = warpzone_first;
	warpzone_first = self;
	WarpZone_ChainAdd(self);
}

vector WarpZone_Camera_camera_transform(vector org, vector ang)
{
    // a fixed camera view
    trace_endpos = self.enemy.origin;
    makevectors(self.enemy.velocity);
    return trace_endpos;
}

void spawnfunc_func_camera(void)
{
    if(warpzone_maybe_remove())
        return;

	if(!self.scale)
		self.scale = self.modelscale;
	if(!self.scale)
		self.scale = 1;
 	if(self.model != "")
 	{
 		precache_model(self.model);
 		setmodel(self, self.model); // no precision needed
	}
	setorigin(self, self.origin);
	if(self.scale)
		setsize(self, self.mins * self.scale, self.maxs * self.scale);
	else
		setsize(self, self.mins, self.maxs);
	if(!self.solid)
		self.solid = SOLID_BSP;
	else if(self.solid < 0)
		self.solid = SOLID_NOT;
	self.SendEntity = WarpZone_Camera_Send;
	self.SendFlags = 0xFFFFFF;
	self.warpzone_next = warpzone_camera_first;
    self.camera_transform = WarpZone_Camera_camera_transform;
	warpzone_camera_first = self;
}

void WarpZone_StartFrame()
{
	entity e;
	if(warpzone_initialized == 0)
	{
		warpzone_initialized = 1;
		e = self;
		for(self = warpzone_first; self; self = self.warpzone_next)
			WarpZone_InitStep_FindTarget();
		for(self = warpzone_position_first; self; self = self.warpzone_next)
			WarpZonePosition_InitStep_FindTarget();
		for(self = warpzone_camera_first; self; self = self.warpzone_next)
			WarpZoneCamera_InitStep_FindTarget();
		for(self = warpzone_first; self; self = self.warpzone_next)
			WarpZone_InitStep_UpdateTransform();
		for(self = warpzone_first; self; self = self.warpzone_next)
			WarpZone_InitStep_FinalizeTransform();
		self = e;
	}

	for(e = world; (e = nextent(e)); )
		WarpZone_StoreProjectileData(e);
}

void WarpZone_HandleObserver() {
    if(!warpzone_chain_begin)
        return;

    var vf = v_forward, vr = v_right, vu = v_up;
    var wz = WarpZone_Find(self.absmin, self.absmax);

    if(!wz)
        return;

    using(other = self) using(self = wz)
        WarpZone_Touch();

    v_forward = vf;
    v_right = vr;
    v_right = vu;
}
