// Thin wrapper over Supabase's auto-generated REST API (PostgREST).
// Every write goes through an RPC function defined in
// supabase/migrations/0001_init.sql (and later migrations) -- see those
// files for the actual security model (passcode re-checked server-side on
// every call; the last name a caller passes is attribution only, never
// itself verified).
const API = (() => {
  const cfg = window.SUPABASE_CONFIG || {};
  const BASE = (cfg.url || "").replace(/\/$/, "");
  const KEY = cfg.anonKey || "";

  async function rest(path, opts = {}) {
    const res = await fetch(BASE + "/rest/v1/" + path, {
      ...opts,
      headers: {
        apikey: KEY,
        Authorization: "Bearer " + KEY,
        "Content-Type": "application/json",
        ...(opts.headers || {}),
      },
    });
    if (!res.ok) {
      let message = res.statusText;
      try {
        const body = await res.json();
        message = body.message || body.error_description || message;
      } catch (e) {}
      throw new Error(message);
    }
    if (res.status === 204) return null;
    return res.json();
  }

  function rpc(fn, args) {
    return rest("rpc/" + fn, { method: "POST", body: JSON.stringify(args) });
  }

  // Uploads straight to Supabase Storage (bucket set up in
  // supabase/migrations/0007_directory_photos.sql) and returns the
  // public URL. Not passcode-gated -- see that migration's notes on why
  // that matches this app's existing security model.
  // unguessableName: a 128-bit random name instead of timestamp + 6
  // chars -- for buckets with no listing policy, where the URL itself is
  // the only thing keeping a file private (commission proof).
  async function uploadPublicFile(bucket, file, unguessableName) {
    const ext = (file.name.split(".").pop() || "jpg").toLowerCase().replace(/[^a-z0-9]/g, "") || "jpg";
    const rand = unguessableName
      ? Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("")
      : Date.now() + "-" + Math.random().toString(36).slice(2, 8);
    const path = rand + "." + ext;
    const res = await fetch(BASE + "/storage/v1/object/" + bucket + "/" + path, {
      method: "POST",
      headers: {
        apikey: KEY,
        Authorization: "Bearer " + KEY,
        "Content-Type": file.type || "application/octet-stream",
      },
      body: file,
    });
    if (!res.ok) {
      let message = res.statusText;
      try {
        const body = await res.json();
        message = body.message || body.error || message;
      } catch (e) {}
      throw new Error(message);
    }
    return BASE + "/storage/v1/object/public/" + bucket + "/" + path;
  }

  return {
    configured() {
      return !!(BASE && KEY) && !BASE.includes("YOUR-PROJECT-REF");
    },

    // ---- reads ----
    listDepartments() { return rest("departments?select=id,name,code"); },
    listSops() { return rest("sops?select=*"); },
    listSopEvents() { return rest("sop_events?select=*"); },
    listSuggestions() { return rest("suggestions?select=*"); },
    listSopEditProposals() { return rest("sop_edit_proposals?select=*"); },
    listDirectory() { return rest("directory_entries?select=*"); },
    listDirectoryEditProposals() { return rest("directory_edit_proposals?select=*"); },

    // ---- writes (all passcode-gated server-side) ----
    login(loginId, passcode) {
      return rpc("login", { p_login_id: loginId, p_passcode: passcode }).then((rows) => rows[0]);
    },
    approveSop(sopId, loginId, passcode, lastName) {
      return rpc("approve_sop", { p_sop_id: sopId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    disapproveSop(sopId, loginId, passcode, lastName) {
      return rpc("disapprove_sop", { p_sop_id: sopId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    // Admin-only: applies immediately. A Member's edit goes through
    // proposeSopEdit/approveSopEdit/rejectSopEdit below instead.
    editSop(sopId, loginId, passcode, lastName, fields) {
      return rpc("edit_sop", { p_sop_id: sopId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_fields: fields });
    },
    addSop(loginId, passcode, lastName, departmentTag, sop) {
      return rpc("add_sop", { p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_department_tag: departmentTag, p_sop: sop });
    },
    // Skips the structured form -- attaches a raw file instead, pending
    // an Admin converting it into a full SOP (see 0009_sop_document_upload.sql).
    // forms is optional supplementary links (Loom video, related doc, etc.
    // -- see 0013_add_sop_document_forms.sql).
    addSopDocument(loginId, passcode, lastName, departmentTag, title, fileUrl, fileName, notes, forms) {
      return rpc("add_sop_document", {
        p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_department_tag: departmentTag,
        p_title: title, p_file_url: fileUrl, p_file_name: fileName, p_notes: notes, p_forms: forms || [],
      });
    },
    uploadSopDocument(file) {
      return uploadPublicFile("sop-documents", file);
    },
    addSuggestion(sopId, loginId, passcode, lastName, text) {
      return rpc("add_suggestion", { p_sop_id: sopId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_text: text });
    },
    approveSuggestion(suggestionId, loginId, passcode, lastName) {
      return rpc("approve_suggestion", { p_suggestion_id: suggestionId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    deleteSuggestion(suggestionId, loginId, passcode, lastName) {
      return rpc("delete_suggestion", { p_suggestion_id: suggestionId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    proposeSopEdit(sopId, loginId, passcode, lastName, fields) {
      return rpc("propose_sop_edit", { p_sop_id: sopId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_fields: fields });
    },
    approveSopEdit(proposalId, loginId, passcode, lastName) {
      return rpc("approve_sop_edit", { p_proposal_id: proposalId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    rejectSopEdit(proposalId, loginId, passcode, lastName) {
      return rpc("reject_sop_edit", { p_proposal_id: proposalId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },

    addDirectoryEntry(loginId, passcode, lastName, entry) {
      return rpc("add_directory_entry", { p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_entry: entry });
    },
    approveDirectoryEntry(entryId, loginId, passcode, lastName) {
      return rpc("approve_directory_entry", { p_entry_id: entryId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    disapproveDirectoryEntry(entryId, loginId, passcode, lastName) {
      return rpc("disapprove_directory_entry", { p_entry_id: entryId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    editDirectoryEntry(entryId, loginId, passcode, lastName, fields) {
      return rpc("edit_directory_entry", { p_entry_id: entryId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_fields: fields });
    },
    proposeDirectoryEdit(entryId, loginId, passcode, lastName, fields) {
      return rpc("propose_directory_edit", { p_entry_id: entryId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_fields: fields });
    },
    approveDirectoryEdit(proposalId, loginId, passcode, lastName) {
      return rpc("approve_directory_edit", { p_proposal_id: proposalId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    rejectDirectoryEdit(proposalId, loginId, passcode, lastName) {
      return rpc("reject_directory_edit", { p_proposal_id: proposalId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
    },
    uploadDirectoryPhoto(file) {
      return uploadPublicFile("directory-photos", file);
    },

    // ---- Commission review (0018_commission_review.sql) ----
    // Separate per-person logins, NOT the shared Admin/Member ones: every
    // call re-checks that person's own passcode, and commission data is
    // only ever readable through these RPCs (never a plain table read).
    listCommissionPeople() { return rpc("list_commission_people", {}); },
    commissionLogin(personId, passcode) {
      return rpc("commission_login", { p_person_id: personId, p_passcode: passcode }).then((rows) => rows[0]);
    },
    commissionBoard(personId, passcode, period) {
      return rpc("commission_board", { p_person_id: personId, p_passcode: passcode, p_period: period || null });
    },
    commissionAnswer(personId, passcode, flagId, reason, caseText, proof) {
      return rpc("commission_answer", { p_person_id: personId, p_passcode: passcode, p_flag_id: flagId, p_reason: reason, p_case: caseText, p_proof: proof || [] });
    },
    commissionDecide(personId, passcode, flagId, decision, waived, note) {
      return rpc("commission_decide", { p_person_id: personId, p_passcode: passcode, p_flag_id: flagId, p_decision: decision, p_waived: waived, p_note: note || null });
    },
    commissionAsk(personId, passcode, flagId, question) {
      return rpc("commission_ask", { p_person_id: personId, p_passcode: passcode, p_flag_id: flagId, p_question: question });
    },
    commissionEscalate(personId, passcode, flagId, note) {
      return rpc("commission_escalate", { p_person_id: personId, p_passcode: passcode, p_flag_id: flagId, p_note: note || null });
    },
    commissionImport(personId, passcode, rows) {
      return rpc("commission_import", { p_person_id: personId, p_passcode: passcode, p_rows: rows });
    },
    commissionSignOffWeek(personId, passcode, period, week) {
      return rpc("commission_sign_off_week", { p_person_id: personId, p_passcode: passcode, p_period: period, p_week: week });
    },
    commissionWeeklyPing(personId, passcode, send) {
      return rpc("commission_post_weekly_ping", { p_person_id: personId, p_passcode: passcode, p_send: !!send });
    },
    uploadCommissionProof(file) {
      return uploadPublicFile("commission-proof", file, true);
    },
  };
})();
