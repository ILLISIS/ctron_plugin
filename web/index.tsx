import React, { useCallback, useContext, useEffect, useMemo, useSyncExternalStore } from "react";

import { BaseWebPlugin, ControlContext } from "@clusterio/web_ui";
import * as lib from "@clusterio/lib";

import * as messages from "../messages";
import JobsPage from "./pages/JobsPage";

export class WebPlugin extends BaseWebPlugin {
	subscriber!: lib.EventSubscriber<typeof messages.ConstructronJobUpdate>;

	async init() {
		this.subscriber = new lib.EventSubscriber(messages.ConstructronJobUpdate, this.control);
		this.pages = [
			{
				path: "/ctron_plugin",
				sidebarName: "Constructron jobs",
				permission: "ctron_plugin.jobs.read",
				content: <JobsPage />,
			},
		];
	}

	useJobs() {
		const control = useContext(ControlContext);

		// Keep subscription alive.
		useEffect(() => {
			let unsubscribe: undefined | (() => void);
			try {
				unsubscribe = this.subscriber.subscribe(() => { /* noop */ });
			} catch {
				// ignore
			}
			return () => unsubscribe?.();
		}, [control]);

		const subscribe = useCallback(
			(cb: () => void) => this.subscriber.subscribe((_event, _synced) => cb()),
			[control]
		);

		const snapshot = useSyncExternalStore(
			subscribe,
			() => this.subscriber.getSnapshot(),
		) as readonly [ReadonlyMap<string | number, Readonly<messages.ConstructronJobValue>>, boolean];

		return useMemo(() => {
			const [values] = snapshot;
			return [...values.values()];
		}, [snapshot]);
	}
}
