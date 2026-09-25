-- A cloud placeholder that was never downloaded no longer gets a document: it has
-- no content to index, and the empty row only showed up as a blank document.
--
-- This removes the rows older builds wrote for such files. A row that was indexed
-- first and marked as a placeholder only later, after the sync client evicted the
-- file, still has its chunks; it goes back to 'ok', since those chunks are valid.
--
-- Idempotent: safe to re-run.

DELETE FROM documents d
 WHERE d.state = 'placeholder'
   AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.document_id = d.id);

UPDATE documents
   SET state = 'ok', error = NULL
 WHERE state = 'placeholder';
