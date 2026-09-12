"""Reconcile pending previews using persisted identities, without media I/O."""

from dataclasses import dataclass

from app.models import OrganizePreviewRecord


ORGANIZED_STATES = frozenset({"organized", "organized_task_removed", "seeding_stopped"})


@dataclass
class PendingPreview:
    record: OrganizePreviewRecord
    remaining_sources: tuple[str, ...]
    completed_count: int


def pending_queue_previews(previews, history, results):
    """Project active work using the complete persisted download-history list.

    A removed or missing owner retires its task preview, not its unresolved
    files. Standalone manual previews have no owner and remain eligible. The
    history list must be the complete persisted list, never a downloader cache.
    """
    downloads = {item.id: item for item in history}
    eligible = [
        record for record in previews
        if record.preview.download_record_id is None or (
            record.preview.download_record_id in downloads
            and downloads[record.preview.download_record_id].status != "deleted"
        )
    ]
    return pending_previews(eligible, history, results)


def completed_preview_tasks(previews, history, results):
    """Retire stale history summaries only when a complete mapping has evidence."""
    unresolved = {
        item.record.preview.download_record_id
        for item in pending_previews(previews, history, results)
    }
    return {
        record.preview.download_record_id
        for record in previews
        if record.preview.download_record_id is not None
        and record.preview.download_record_id not in unresolved
        and record.preview.file_mappings
        and not record.preview.partial_batch
        and all(row.status != "skipped" for row in record.preview.file_mappings)
    }


def pending_previews(previews, history, results):
    downloads = {item.id: item for item in history}
    outcomes = {}
    ordered = sorted(enumerate(results), key=lambda pair: (pair[1].created_at, pair[1].id, pair[0]), reverse=True)
    for _, result in ordered:
        if not result.preview.is_batch:
            outcomes.setdefault(result.source_path, []).append(result)

    seen = set()
    pending = []
    for record in sorted(previews, key=lambda item: (item.created_at, item.id), reverse=True):
        preview = record.preview
        task_id = preview.download_record_id
        download = downloads.get(task_id)
        if download and download.status in ORGANIZED_STATES:
            continue
        mappings = [row for row in preview.file_mappings if row.status != "skipped"]
        sources = [row.source_path for row in mappings] if mappings else [preview.source_path]
        remaining = []
        completed = 0
        for source in sources:
            if not source:
                # Unknown identities must not merge unrelated requests.
                remaining.append(source)
                continue
            identity = (task_id if task_id is not None else ("preview", record.id), source)
            if identity in seen:
                continue
            seen.add(identity)
            latest = next((
                result for result in outcomes.get(source, [])
                if result.preview.download_record_id == task_id
                and (task_id is not None or result.preview.preview_id == record.id)
            ), None)
            # A newer failure must not be masked by a historical success.
            # A bare skipped result does not prove media was written either.
            if latest is not None and latest.status == "moved":
                completed += 1
            else:
                remaining.append(source)
        if remaining:
            pending.append(PendingPreview(record, tuple(remaining), completed))
    return pending
