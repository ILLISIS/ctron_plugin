/* eslint-disable new-cap */
import { Type, type TSchema } from "@sinclair/typebox";

// Every ctron_pluginv2 message shape, declared once (spec §9, R-13). Payloads from Lua are checked against these on
// UE's bridge (the trust boundary); payloads to Lua are checked field by field in Lua. Fields follow spec §4.3
// (records), §6.9 (assign), §6.12 (UI rows) and §7 (routes, portals). What the spec writes as "| null" is an absent
// field here: Lua has no null, so a Lua-facing payload marks it Optional.

/** Factorio writes an empty Lua table as {}, not [] (R-18): a list from Lua is either. As UE's routing LuaList. */
export const List = <T extends TSchema>(item: T) => Type.Union([
	Type.Array(item),
	Type.Object({}, { additionalProperties: false }),
]);
/** A List's items: [] for {}. */
export function list<T>(v: readonly T[] | object | undefined): T[] {
	return Array.isArray(v) ? (v as T[]) : [];
}

/**
 * Every up message but ct.portals encodes to at most this many bytes, envelope included (R-125, R-164): a bridge
 * message of 4000 bytes or more goes through Clusterio's file path, which is read asynchronously and overtaken by
 * later lines.
 */
export const UP_LIMIT = 3900;
/**
 * The bytes of records and rm ids one ct.delta or ct.snapshot part carries (Lua's parts_core.BUDGET); a record alone
 * in its part may exceed it, up to UP_LIMIT (R-164).
 */
export const PART_BUDGET = 2500;
/** The most a job detail encodes to; Lua drops the task list first to stay under it (§6.12). */
export const DETAIL_BYTES = 3000;

const Opt = <T extends TSchema>(schema: T) => Type.Optional(schema);
const Str = Type.String();
const Int = Type.Integer();
const Num = Type.Number();
const Bool = Type.Boolean();

export const JobKind = Type.Union([
	Type.Literal("construction"), Type.Literal("deconstruction"), Type.Literal("upgrade"), Type.Literal("repair"),
	Type.Literal("destroy"), Type.Literal("cargo"),
]);
/** Cargo has no cells: it comes from needs (§4.2). */
export const CellKind = Type.Union([
	Type.Literal("construction"), Type.Literal("deconstruction"), Type.Literal("upgrade"), Type.Literal("repair"),
	Type.Literal("destroy"),
]);
export const Role = Type.Union([Type.Literal("worker"), Type.Literal("leader"), Type.Literal("minion")]);
/** A run's state (§5.3). */
export const RunState = Type.Union([
	Type.Literal("to_station"), Type.Literal("loading"), Type.Literal("to_work"), Type.Literal("at_task"),
	Type.Literal("fight"), Type.Literal("follow"), Type.Literal("to_dest"), Type.Literal("deliver"),
	Type.Literal("leave_work"), Type.Literal("returning"), Type.Literal("unloading"),
]);
export const CtronState = Type.Union([Type.Literal("idle"), Type.Literal("busy"), Type.Literal("unfit")]);

/** An item: [name, quality, count], or [name, quality, count, stack] where the controller counts slots (§4.3). */
export const Item = Type.Union([Type.Tuple([Str, Str, Int]), Type.Tuple([Str, Str, Int, Int])]);
export const Items = List(Item);
export const Pos = Type.Object({ x: Num, y: Num });
/** Factorio's BoundingBox in its explicit form: a cell's or a share's area. */
export const Area = Type.Object({ left_top: Pos, right_bottom: Pos });
/** A station as a place (§4.4): where a run loads and finishes, or a cargo destination. */
export const StationRef = Type.Object({ sid: Str, inst: Int, x: Num, y: Num });
/** A chosen item, [name, quality] (settings). */
export const ItemRef = Type.Tuple([Str, Str]);

// Records, tile → controller (§4.3).
/** Per restock profile (§5.4): normal, destroy, cargo. */
const Profiles = <T extends TSchema>(t: T) => Type.Object({ normal: t, destroy: t, cargo: t });
/** label and a station's name are at most 60 characters (Lua truncates). */
export const Ctron = Type.Object({
	cid: Str, surface: Str, name: Str, quality: Str, label: Opt(Str), x: Num, y: Num, state: CtronState,
	why: Opt(Str), jid: Opt(Str), free: Profiles(Int), restock: Profiles(Items),
});
export const Station = Type.Object({ sid: Str, surface: Str, name: Str, x: Num, y: Num });
// A work cell (R-22); bring has at most 30 entries: scanned, area, center, bring,
// out and n come once a scan has completed (R-127).
export const Cell = Type.Object({
	wid: Str, surface: Str, kind: CellKind, since: Int, due: Int, tool: Bool,
	scanned: Opt(Int), area: Opt(Area), center: Opt(Pos), bring: Opt(Items), out: Opt(Int), n: Opt(Int),
});
/** One cargo slot of a station with its network's count: [name, quality, min, max, count, stack]; at most 30. */
export const NeedSlot = Type.Tuple([Str, Str, Int, Int, Int, Int]);
export const Need = Type.Object({ sid: Str, surface: Str, slots: List(NeedSlot) });
export const Share = Type.Object({ wid: Str, bring: Items, out: Int });
/**
 * One tile's part of a job (§6.1): the cids of its runs on this tile; state is the worker's or leader's run's. cargo is
 * the destination and items of a cargo job.
 */
export const Job = Type.Object({
	jid: Str, kind: JobKind, surface: Str, members: List(Str), state: RunState,
	status: Str, arg: Opt(Type.Union([Str, Num])), tasks: Type.Tuple([Int, Int]), station: StationRef,
	shares: List(Share), left: Opt(Int), missing: Opt(Items),
	cargo: Opt(Type.Object({ dest: StationRef, items: Items })),
	/** The squad leader's cid, on a part without the leader (squads.md §6). */
	lead: Opt(Str),
});

// Settings (§4.6).
export const Kinds = Type.Object({
	construction: Bool, rebuild: Bool, deconstruction: Bool, upgrade: Bool, repair: Bool, destroy: Bool,
});
// Its own declaration: inline in SettingsPatch, typebox 0.30 (Clusterio 2.0.2) fails it with TS2589.
const KindsPatch = Type.Partial(Kinds);
const settingFields = {
	job_start_delay: Int, debug: Bool, horde: Bool, zone_restriction: Bool, robot: ItemRef, robot_count: Int,
	repair_tool: ItemRef, ammo: ItemRef, ammo_count: Int, atomic_count: Int, min_cluster: Int, minions: Int,
};
/** Every setting: a tile's prototype-derived defaults, or effective values. atomic is absent for none. */
export const Settings = Type.Object({ ...settingFields, kinds: Kinds, atomic: Opt(ItemRef) });
/** Some settings, kinds partly too: an edit, or one scope's stored overrides. */
export const SettingsPatch = Type.Partial(Type.Object({
	...settingFields, kinds: KindsPatch, atomic: ItemRef,
}));
/** The controller's overrides by scope, "*" or a surface name (R-68). The global keys live under "*". */
export const Overrides = Type.Record(Str, SettingsPatch);

// Up: Lua → TS (§9.2).
const Changes = <T extends TSchema>(record: T) => Type.Object({ up: List(record), rm: List(Str) });
/** One part of a tile's snapshot (R-125): applied as one replace at the last part; defaults ride part 1. */
export const Snapshot = Type.Object({
	seq: Int, part: Int, parts: Int, ctrons: List(Ctron), stations: List(Station),
	cells: List(Cell), needs: List(Need), jobs: List(Job),
	defaults: Opt(Settings),
});
/**
 * What changed since the last delta, by record kind; rm lists ids (cid, sid, wid, a need's sid, jid). A delta
 * larger than a message goes in consecutive parts, cells first (R-125): each part is a Delta of its own.
 */
export const Delta = Type.Object({
	ctrons: Opt(Changes(Ctron)), stations: Opt(Changes(Station)), cells: Opt(Changes(Cell)), needs: Opt(Changes(Need)),
	jobs: Opt(Changes(Job)),
});
export const JobEventKind = Type.Union([
	Type.Literal("adopted"), Type.Literal("rejected"), Type.Literal("short"), Type.Literal("trash_full"),
	Type.Literal("failed"), Type.Literal("lost"), Type.Literal("done"), Type.Literal("unknown"),
	Type.Literal("left"),
]);
export const JobEvent = Type.Object({
	jid: Str, ev: JobEventKind, tick: Int, cid: Opt(Str), why: Opt(Str), missing: Opt(Items), items: Opt(Items),
	wid: Opt(Str), left: Opt(Int),
});
/**
 * One covering network of one query, its stations grouped at answer time (R-140); cover: true for all items, else the
 * indexes of those covered. A tile sends a reply in parts, one record per (query, network) (R-151).
 */
export const StockRec = Type.Object({
	qid: Str, sids: List(Str), cover: Type.Union([Type.Literal(true), List(Int)]),
});
/** The records of all of a reply's parts, concatenated: a StockQueryRequest's answer. */
export const StockResult = List(StockRec);
export const StockReply = Type.Object({ req: Str, part: Int, parts: Int, r: StockResult });
export const RouteAsk = Type.Object({
	req: Str, jid: Opt(Str), surface: Str, from: Pos,
	to: Type.Object({ inst: Int, x: Num, y: Num }), avoid: List(Str),
});
/** A window ("w", on edge at window k, open run [lo, hi]) or a station dock ("s"), with its component (§7.4). */
export const PortalNode = Type.Object({
	id: Int, kind: Type.Union([Type.Literal("w"), Type.Literal("s")]), edge: Opt(Str), k: Opt(Int), lo: Opt(Num),
	hi: Opt(Num), x: Num, y: Num, comp: Int, sid: Opt(Str),
});
/** One tile's portal graph on one surface, a full replace; the controller links same-comp nodes (R-150). */
export const Portals = Type.Object({
	surface: Str, epoch: Int, nodes: List(PortalNode),
});
/** A job's live detail for Job Details (§6.12): requests are [name, quality, want, have]. */
export const Detail = Type.Object({
	members: List(Type.Object({
		cid: Str, x: Num, y: Num, trunk: Items, ammo: Items, trash: Items,
		requests: List(Type.Tuple([Str, Str, Int, Int])),
	})),
	tasks: List(Type.Tuple([Num, Num])), station: StationRef,
});
export const DetailReply = Type.Object({ req: Str, detail: Opt(Detail) });
/** A watch is (surface, tile filter, expanded pending group "<owner>|<kind>") (R-134). */
export const Watch = Type.Object({ surface: Str, tile: Opt(Int), expand: Opt(Str) });
export const UiWatch = Type.Object({ surface: Str, tile: Opt(Int), expand: Opt(Str), on: Bool });
/** A cancel from a screen (§6.9); no id = every one of that kind on the surface (ctrl-click). */
export const UiCancel = Type.Object({
	target: Type.Union([Type.Literal("work"), Type.Literal("job")]), kind: JobKind, surface: Str, id: Opt(Str),
});
export const UiDrop = Type.Object({ jid: Opt(Str), surface: Str, name: Str, quality: Str });
/** A station edit from a screen (§8.4): the slots (30 at most) and/or the name; an empty slots list clears them. */
const CargoSlot = Type.Tuple([Str, Str, Int, Int]);
export const UiCargo = Type.Object({ sid: Str, slots: Opt(List(CargoSlot)), name: Opt(Str) });
export const UiDetailAsk = Type.Object({ req: Str, jid: Str });
/** An in-game settings edit (§6.11): no surface = the global keys; "*" = every surface. */
export const SettingsSet = Type.Object({ surface: Opt(Str), patch: SettingsPatch });

// Down: TS → Lua (§9.2), each message at most 3 KB (R-15).
export const WorkShare = Type.Object({ wid: Str, key: Int, area: Area, bring: Type.Array(Item), out: Int });
/**
 * lead present = a minion assign: every member is a minion adopted here, loading at station; lead names the leader and
 * its place. Absent on a destroy assign = the leader's: members[1] is adopted and members[2..] is its squad list.
 */
export const JobAssign = Type.Object({
	jid: Str, kind: JobKind, surface: Str, station: StationRef, members: Type.Array(Str), work: Type.Array(WorkShare),
	cargo: Opt(Type.Object({ dest: StationRef, items: Type.Array(Item) })),
	lead: Opt(Type.Object({ cid: Str, inst: Int, x: Num, y: Num })),
});
export const JobStation = Type.Object({ jid: Str, cid: Str, station: StationRef, why: Str });
export const JobCancel = Type.Object({ jid: Str });
/** A squad's state for its parts: the leader's place, minions gone from it, and its release (squads.md §4.4). */
export const JobSquad = Type.Object({
	jid: Str, lead: Opt(Type.Object({ inst: Int, x: Num, y: Num })), gone: Type.Array(Str), done: Bool,
});
export const JobDrop = Type.Object({ jid: Opt(Str), surface: Str, name: Str, quality: Str });
/** A station edit relayed to the station's tile; the controller has made slots a plain array. */
export const StationSet = Type.Object({
	sid: Str, slots: Opt(Type.Array(CargoSlot, { maxItems: 30 })), name: Opt(Str),
});
/** Forget cells: these wids, or every cell of kind on surface. */
export const WorkClear = Type.Object({ wids: Opt(Type.Array(Str)), surface: Opt(Str), kind: Opt(CellKind) });
export const StockQ = Type.Object({
	qid: Str, mode: Type.Union([Type.Literal("supply"), Type.Literal("drop")]), items: Type.Array(Item),
	exclude_sid: Opt(Str),
});
export const StockQuery = Type.Object({ req: Str, q: Type.Array(StockQ) });
/** A route (§7.5): hops only, each an edge, the crossing x in side a's frame and the instance it leaves. */
export const Route = Type.Object({
	v: Type.Literal(1), goal: Type.Object({ inst: Int, x: Num, y: Num }),
	hops: Type.Array(Type.Object({ edge: Str, x: Num, from: Int })), graph: Int,
});
export const RouteReply = Type.Object({ req: Str, route: Opt(Route) });
export const DetailFetch = Type.Object({ req: Str, jid: Str });
const key = (prefix: string) => Type.String({ pattern: `^${prefix}:` });
/** Every row carries its section and its position in it (§6.12). */
const Place = { sec: Str, ord: Int };
export const WorkSt = Type.Union([
	Type.Literal("delay"), Type.Literal("open"), Type.Literal("backoff"), Type.Literal("waiting_squad"),
]);
/** Why a pending cell waits (§4.2, R-130). */
export const WorkWhy = Type.Union([
	Type.Literal("no_ctron"), Type.Literal("unreachable"), Type.Literal("no_supplier"), Type.Literal("failed"),
	Type.Literal("no_progress"),
]);
/** UI rows (§6.12), keyed "w:", "g:", "j:", "c:", "s:" or "n:" plus the id. */
export const WorkRow = Type.Object({
	...Place, key: key("w"), kind: CellKind, owner: Int, ownerName: Str, c: Opt(Type.Tuple([Num, Num])),
	st: WorkSt, why: Opt(WorkWhy), rem: Int, committed: Int, firstSeenMs: Num, dueAtMs: Opt(Num), tool: Bool,
});
/** A pending group: one row per (owner tile, kind). */
export const GroupRow = Type.Object({
	...Place, key: key("g"), kind: CellKind, owner: Int, ownerName: Str, n: Int, oldestMs: Num,
	st: WorkSt, why: Opt(WorkWhy),
});
const jobFields = {
	key: key("j"), kind: JobKind, at: Int, atName: Str,
	worker: Str, n: Int, state: Str,
	status: Str, arg: Opt(Type.Union([Str, Num])), tasks: Type.Tuple([Int, Int]),
	station: Type.Object({ sid: Str, name: Str, inst: Int, x: Num, y: Num }), missing: Opt(Type.Array(Item)),
};
export const JobRow = Type.Object({ ...Place, ...jobFields });
export const CtronRow = Type.Object({
	...Place, key: key("c"), at: Int, atName: Str, name: Str, label: Opt(Str), state: CtronState,
	why: Opt(Str), jid: Opt(Str), kind: Opt(JobKind), status: Opt(Str), arg: Opt(Type.Union([Str, Num])),
	x: Opt(Num), y: Opt(Num),
});
export const StationRow = Type.Object({
	...Place, key: key("s"), at: Int, atName: Str, name: Str, x: Num, y: Num,
});
export const NeedRow = Type.Object({
	...Place, key: key("n"), sid: Str, slots: Type.Array(Type.Tuple([Str, Str, Int, Int, Int])),
	order: Opt(List(Int)), why: Opt(Type.Literal("no_supplier")),
});
export const Row = Type.Union([WorkRow, GroupRow, JobRow, CtronRow, StationRow, NeedRow]);
export const UiList = Type.Object({
	watch: Watch, seq: Int, full: Bool, part: Int, parts: Int, up: Type.Array(Row), rm: Type.Array(Str),
	stats: Type.Object({
		total: Int, available: Int, surfaces: Type.Array(Str), tiles: Type.Array(Type.Tuple([Int, Str])),
		now: Num, more: Type.Record(Str, Int), waiting: Type.Array(Type.Tuple([Str, Str, Int])),
	}),
});
/** What a window shows: a tile's detail plus the job's list row, added by the controller (§6.12). */
// JobRow without its Place, from the fields: Type.Omit(JobRow, ...) fails typebox 0.30 (Clusterio 2.0.2) with TS2589.
export const DetailFull = Type.Composite([Detail, Type.Object({ job: Type.Object(jobFields) })]);
export const UiDetail = Type.Object({ req: Str, detail: Opt(DetailFull) });
export const UiLink = Type.Object({ up: Bool });
/** surfaces = the schedulable set (R-145). */
export const SettingsState = Type.Object({ overrides: Overrides, surfaces: Type.Array(Str) });

/** Lua → TS: every bridge type of spec §9.2 ("up") and its payload. "trace" is UE's own. */
export const UP = {
	"ct.snapshot": Snapshot, "ct.delta": Delta, "ct.job.event": JobEvent, "ct.stock.reply": StockReply,
	"ct.route.ask": RouteAsk, "ct.portals": Portals, "ct.detail.reply": DetailReply, "ct.ui.watch": UiWatch,
	"ct.ui.cancel": UiCancel, "ct.ui.drop": UiDrop, "ct.ui.cargo": UiCargo, "ct.ui.detail.ask": UiDetailAsk,
	"ct.settings.set": SettingsSet,
};
/** TS → Lua: every bridge type of spec §9.2 ("down") and its payload. */
export const DOWN = {
	"ct.snapshot.request": Type.Object({}), "ct.job.assign": JobAssign, "ct.job.station": JobStation,
	"ct.job.cancel": JobCancel, "ct.job.squad": JobSquad, "ct.job.drop": JobDrop, "ct.station.set": StationSet,
	"ct.work.clear": WorkClear,
	"ct.stock.query": StockQuery,
	"ct.route.reply": RouteReply, "ct.detail.fetch": DetailFetch, "ct.ui.list": UiList, "ct.ui.detail": UiDetail,
	"ct.ui.link": UiLink, "ct.settings": SettingsState,
};
