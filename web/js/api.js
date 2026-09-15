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
    addSuggestion(sopId, loginId, passcode, lastName, text) {
      return rpc("add_suggestion", { p_sop_id: sopId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName, p_text: text });
    },
    approveSuggestion(suggestionId, loginId, passcode, lastName) {
      return rpc("approve_suggestion", { p_suggestion_id: suggestionId, p_login_id: loginId, p_passcode: passcode, p_last_name: lastName });
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
  };
})();
