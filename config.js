// Surge Recruit — runtime config (public values only; the anon key is safe to ship in a browser)
window.SR_CONFIG = {
  SUPABASE_URL: "https://szdzbycppkavfwuzlljh.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN6ZHpieWNwcGthdmZ3dXpsbGpoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk1ODIxNzgsImV4cCI6MjA5NTE1ODE3OH0.Jw21eHChMDHlskSs2PegmBXLYNIQkjl8GByOIApadhA",
  COMPANY: "Surge Partners",
  // Candidate statuses (same pipeline SalesDraft uses)
  STATUSES: [
    "New","Disqualified",
    "Interview Scheduled","Interview Canceled","Interview Missed","Interview Missed Manager","Interview Reschedule","Interview Qualified","Interview Hiring Process Change",
    "NHO Scheduled","NHO Canceled","NHO Missed","NHO Missed Manager","NHO Reschedule","NHO Qualified","NHO Hiring Process Change",
    "Position Closed"
  ]
};
