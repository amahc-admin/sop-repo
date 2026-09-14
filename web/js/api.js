// Thin wrapper over Supabase's auto-generated REST API (PostgREST).
// Every write goes through an RPC function defined in
// supabase/migrations/0001_init.sql -- see that file for the actual
// security model (passcode re-checked server-side on every call).
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

    // ---- writes (all passcode-gated server-side) ----
    login(departmentId, passcode) {
      return rpc("login_department", { p_department_id: departmentId, p_passcode: passcode }).then((rows) => rows[0]);
    },
    approveSop(sopId, departmentId, passcode) {
      return rpc("approve_sop", { p_sop_id: sopId, p_department_id: departmentId, p_passcode: passcode });
    },
    disapproveSop(sopId, departmentId, passcode) {
      return rpc("disapprove_sop", { p_sop_id: sopId, p_department_id: departmentId, p_passcode: passcode });
    },
    editSop(sopId, departmentId, passcode, fields) {
      return rpc("edit_sop", { p_sop_id: sopId, p_department_id: departmentId, p_passcode: passcode, p_fields: fields });
    },
    addSop(departmentId, passcode, sop) {
      return rpc("add_sop", { p_department_id: departmentId, p_passcode: passcode, p_sop: sop });
    },
    addSuggestion(sopId, departmentId, passcode, text) {
      return rpc("add_suggestion", { p_sop_id: sopId, p_department_id: departmentId, p_passcode: passcode, p_text: text });
    },
    approveSuggestion(suggestionId, departmentId, passcode) {
      return rpc("approve_suggestion", { p_suggestion_id: suggestionId, p_department_id: departmentId, p_passcode: passcode });
    },
  };
})();
