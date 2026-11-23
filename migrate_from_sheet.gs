/**
 * পুরনো ডাটা (Google Sheet) -> Supabase, একবারের মাইগ্রেশন (ঐচ্ছিক)।
 * ব্যবহার: পুরনো শিটের Apps Script এ নতুন ফাইল হিসেবে পেস্ট করে migrateAll() চালান।
 * এখানে service_role key লাগবে — কাজ শেষে এই ফাইল মুছে ফেলুন, GitHub এ কখনো আপলোড করবেন না।
 */
var SB_URL = 'https://YOUR_PROJECT_REF.supabase.co';
var SB_SERVICE_KEY = 'YOUR_SERVICE_ROLE_KEY';

var MAP = { // শিট ট্যাব -> Supabase টেবিল
  Employees: 'employees', Expense_Vouchers: 'vouchers', Expense_Items: 'items',
  App_Settings: 'settings', Activity_Log: 'activity_log'
};
var NUMERIC = { total: 1, item_count: 1, submit_count: 1, amount: 1, quantity: 1, rate: 1 };

function col_(h) {
  if (h === 'Time') return 'log_time';
  if (h === 'By') return 'by_user';
  return String(h).replace(/ID$/, '_id').replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
}

function migrateAll() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  ['Employees', 'Expense_Vouchers', 'Expense_Items', 'App_Settings', 'Activity_Log'].forEach(function (tab) {
    var sh = ss.getSheetByName(tab);
    if (!sh || sh.getLastRow() < 2) return;
    var vals = sh.getDataRange().getValues(), head = vals[0].map(col_), rows = [];
    for (var i = 1; i < vals.length; i++) {
      if (vals[i][0] === '' || vals[i][0] === null) continue;
      var o = {};
      head.forEach(function (c, j) {
        var v = vals[i][j];
        if (v instanceof Date) v = Utilities.formatDate(v, Session.getScriptTimeZone(), 'yyyy-MM-dd');
        if (c === 'active') o[c] = String(v).toLowerCase() !== 'false';
        else if (c === 'sort_order') o[c] = v === '' ? null : Number(v);
        else if (NUMERIC[c]) o[c] = Number(String(v).replace(/[^0-9.\-]/g, '')) || 0;
        else o[c] = String(v);
      });
      rows.push(o);
    }
    for (var k = 0; k < rows.length; k += 200) post_(MAP[tab], rows.slice(k, k + 200));
    Logger.log(tab + ': ' + rows.length + ' rows');
  });
}

function post_(table, rows) {
  var r = UrlFetchApp.fetch(SB_URL + '/rest/v1/' + table, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: SB_SERVICE_KEY, Authorization: 'Bearer ' + SB_SERVICE_KEY, Prefer: 'resolution=merge-duplicates' },
    payload: JSON.stringify(rows)
  });
  if (r.getResponseCode() >= 300) throw new Error(table + ': ' + r.getContentText());
}
