return {
	PADDLE_OFFSET_Y       = 3.5,

	-- Puck speeds are final velocities in studs/sec. The table is ~13.75 studs
	-- goal to goal, so the ceiling below crosses it in ~0.53s and covers the
	-- centre-to-goal half in ~0.27s — tight, but past the ~0.25s it takes a human
	-- to react at all.
	PUCK_MAX_SPEED        = 26,
	-- Minimum gap between paddle hit *sounds*. The contact itself is no longer
	-- gated on a timer -- a swept test plus a closing-speed check handles that --
	-- so this only stops a dribbled puck machine-gunning the audio. Raising it
	-- will not make hits less responsive.
	HIT_COOLDOWN          = 0.08,
	COUNTDOWN             = 3,
	GOAL_WIN_SCORE        = 7,
	GOAL_PAUSE            = 2,
	-- Air cushion. Fraction of speed the puck keeps per second, applied as
	-- drag^dt so the glide no longer depends on server frame rate. The old value
	-- was per-frame and bled off ~60%/sec, which is nothing like a real table.
	PUCK_DRAG_PER_SECOND  = 0.88,

	-- A hit is resolved as a bounce off a heavy moving wall, which is how a
	-- mallet behaves against a light puck: reflect along the contact normal,
	-- keep most of the sideways slide, then add the paddle's own motion.
	PUCK_RESTITUTION      = 0.8,   -- plastic on plastic
	PUCK_TANGENT_KEEP     = 0.85,  -- sideways slide kept across the face
	PUCK_WALL_RESTITUTION = 0.92,  -- boards take a little out of each bounce

	-- Contact nudge, not a launch: a dead-still paddle touching a dead-still puck
	-- should barely move it. This exists only so the puck can never come to rest
	-- inside the paddle face.
	PUCK_MIN_HIT_SPEED    = 3,

	-- Ceiling on the paddle speed a single hit may transfer. Paddle velocity is
	-- derived from client-sent cursor positions, so one flicked frame can report
	-- a huge number; without this cap that frame becomes an unreturnable shot.
	PADDLE_MAX_EFFECTIVE_SPEED = 14,
	-- How far back from the centre line a paddle spawns, measured along the
	-- table's own goal-to-goal axis into the role's own half. Signless on
	-- purpose: which direction is "Blue" is read off the pads at runtime, not
	-- baked into a world axis here.
	PADDLE_SPAWN_INSET    = 2.2,
	-- Paddle hits play HardHit above this speed and SoftHit below it. The number
	-- compared is the puck speed the hit produces (PuckService.applyPaddleHit),
	-- which lands in [PUCK_MIN_HIT_SPEED, PUCK_MAX_SPEED] = [3, 26]. A full-speed
	-- swing into a resting puck lands around 25, a gentle push around 10.
	HIT_HARD_SPEED        = 16,
	-- Wall bounces below this speed are silent, and one wall sound at most every
	-- cooldown, so a puck grinding along a border doesn't machine-gun.
	WALL_HIT_MIN_SPEED    = 4,
	WALL_HIT_COOLDOWN     = 0.08,

	SEND_RATE             = 1 / 60,
	SPAWN_Y_OFFSET        = 5,
	MIN_DT                = 1 / 240,

	-- Match states (see Shared.FX; duplicated here for server require order)
	STATE_WAITING         = "Waiting",
	STATE_COUNTDOWN       = "Countdown",
	STATE_PLAYING         = "Playing",
	STATE_GOAL            = "Goal",
	STATE_MATCH_OVER      = "MatchOver",

	-- Economy
	STARTING_CASH         = 250,
	CASH_ATTR             = "Cash",
	WAGER_ATTR            = "Wager",
	TIER_ATTR             = "Tier",
	MATCH_OVER_LINGER     = 8,   -- seconds the win card shows before players are released

	-- Consolation payout for the loser, as a fraction of their own stake (0 = winner takes all)
	LOSER_REFUND_RATE     = 0,
}