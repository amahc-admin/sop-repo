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
  async function uploadPublicFile(bucket, file) {
    const ext = (file.name.split(".").pop() || "jpg").toLowerCase().replace(/[^a-z0-9]/g, "") || "jpg";
    const path = Date.now() + "-" + Math.random().toString(36).slice(2, 8) + "." + ext;
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
  };
})();
