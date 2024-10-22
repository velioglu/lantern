CREATE OR REPLACE FUNCTION create_bm25_table(table_name TEXT, id_column TEXT, index_columns TEXT[], drop_if_exists BOOLEAN DEFAULT FALSE)
RETURNS VOID AS $$
DECLARE
    source_column TEXT;
    src_table_exists BOOLEAN;
    dest_table_exists BOOLEAN;
    drop_if_exists_sql TEXT := '';
BEGIN
    -- Concatenate the index columns into a single source column
    source_column := index_columns[1];
    IF cardinality(index_columns) > 1 THEN
        raise exception 'Multiple index columns not supported yet';
    END IF;

    -- Check if the table exists
    EXECUTE format('SELECT to_regclass(%L)      IS NOT NULL', table_name) INTO src_table_exists;
    EXECUTE format('SELECT to_regclass(%L) IS NOT NULL', table_name || 'bm_25') INTO dest_table_exists;
    IF NOT src_table_exists THEN
        RAISE EXCEPTION 'Table "%" does not exist', table_name;
    END IF;
    IF drop_if_exists THEN
        drop_if_exists_sql := 'DROP TABLE IF EXISTS ' || table_name || '_bm25;';
    ELSIF dest_table_exists THEN
        RAISE EXCEPTION 'Table "%" already exists', table_name || '_bm25';
    END IF;

    -- Ideally, would want this to be in a transaction, but transaction blocks in EXECUTE are not implemented
    EXECUTE format('
        %4$s; -- Optionally, drop the table if it exists
        CREATE TABLE %1$I_bm25 AS
        SELECT term,
            -- number of documents containing the term. this is identical to doc_ids_len at bulk construction, but as inserts happen, the two will diverge
            count(%2$I)::integer as term_freq,
            count(%2$I)::integer as doc_ids_len,
            NULL::bloom as doc_ids_bloom,
            array_agg(%2$I ORDER BY %2$I) AS doc_ids,
            array_agg(cardinality(array_positions(%3$I, term)) ORDER BY %2$I) AS fqs,
            array_agg(cardinality(%3$I) ORDER BY %2$I) as doc_lens
        FROM  (
            SELECT DISTINCT ON (%2$I, term) *
            FROM %1$I, unnest(%3$I) AS term) alias
            GROUP BY term;

        CREATE INDEX ON %1$I_bm25 USING hash(term);
        UPDATE %1$I_bm25 SET doc_ids_bloom = array_to_bloom(doc_ids) WHERE cardinality(doc_ids) > 8000;
    ', table_name, id_column, source_column, drop_if_exists_sql);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION search_bm25(table_name TEXT, id_column TEXT, index_columns TEXT[], query TEXT, result_limit INT DEFAULT 10)
RETURNS TABLE(doc_id INT, content_stemmed TEXT[], bm25_score REAL) AS $$
DECLARE
    source_column TEXT;
    join_sql TEXT := '';
BEGIN
    -- Concatenate the index columns into a single source column
    source_column := index_columns[1];
    IF cardinality(index_columns) > 1 THEN
        raise exception 'Multiple index columns not supported yet';
    END IF;

    -- TODO:: text_to_stem_array should not be hard-coded
    -- TODO: get rid of potentially expensive queries on source `table_name` from below
    RETURN QUERY EXECUTE format('
        WITH terms AS (
            SELECT * FROM %1$I_bm25 WHERE term = ANY(text_to_stem_array(%4$L))
        ),
        agg AS (
            SELECT (unnest(bm25_agg(
                terms.*,
                %5$s, -- limit - number of returned results
                (SELECT count(*)::integer from %1$I),
                (SELECT AVG(cardinality(%3$I))::real FROM %1$I),
                1.2,   -- k1 parameter
                0.75   -- b parameter
                ORDER BY doc_ids_len ASC
            ))).* AS res FROM terms
        )
        SELECT agg.doc_id::INT, %1$I.content_stemmed, agg.bm25::REAL
        FROM agg
        LEFT JOIN %1$I
        ON agg.doc_id = %1$I.%2$I
        ORDER BY bm25 DESC
    ', table_name, id_column, source_column, query, result_limit);
END;
$$ LANGUAGE plpgsql;


DROP FUNCTION IF EXISTS consolidate_corpus_bm25;
CREATE FUNCTION consolidate_bm25_table(table_name TEXT, N integer DEFAULT NULL)
RETURNS void AS $$
DECLARE
    term_dup RECORD;
    term_record RECORD;
    merged_doc_ids integer[];
    merged_fqs integer[];
    merged_doc_lens integer[];
    new_doc_ids_bloom bloom;
BEGIN
    -- Loop through each term that appears more than once
    FOR term_dup IN
        EXECUTE format('SELECT term
        FROM %I_bm25
        GROUP BY term
        HAVING COUNT(*) > 1
        LIMIT %L', table_name, N)
    LOOP
        -- Initialize arrays
        new_doc_ids_bloom := NULL;
        merged_doc_ids := '{}';
        merged_fqs := '{}';
        merged_doc_lens := '{}';
        -- Select and merge N rows with the same term
        FOR term_record IN
            EXECUTE format('SELECT term, doc_ids, fqs, doc_lens
            FROM %I_bm25
            WHERE term = term_dup.term
            -- ORDER BY doc_ids[1] -- Order by the first doc_id in the array
            LIMIT %L', table_name, N)
        LOOP
            raise notice 'hmm';
            -- Merge arrays
            merged_doc_ids := array_cat(merged_doc_ids, term_record.doc_ids);
            merged_fqs := array_cat(merged_fqs, term_record.fqs);
            merged_doc_lens := array_cat(merged_doc_lens, term_record.doc_lens);
        END LOOP;
        -- Delete original rows
        EXECUTE format('DELETE FROM %I_bm25
        WHERE term = term_record.term', table_name);
        IF cardinality(merged_doc_ids) > 8000 THEN
            new_doc_ids_bloom := array_to_bloom(merged_doc_ids);
        END IF;
        -- Insert the consolidated row
        EXECUTE format('INSERT INTO %I_bm25 (term, doc_ids, fqs, doc_lens, doc_ids_len, term_freq, doc_ids_bloom)
        VALUES (term_record.term, merged_doc_ids, merged_fqs, merged_doc_lens, cardinality(merged_doc_ids), cardinality(merged_doc_ids), new_doc_ids_bloom)', table_name);
    END LOOP;
END;
$$ LANGUAGE plpgsql;