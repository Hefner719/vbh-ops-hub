/* vbh-config.js — shared across all pages */
const VBH = {
  SUPABASE_URL: 'https://bppirsahciuxrqzitfxa.supabase.co',
  SUPABASE_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJwcGlyc2FoY2l1eHJxeml0ZnhhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0MTExMjcsImV4cCI6MjA5NTk4NzEyN30.Yy3en8gNoTPSVkztlGr6XbUq6ZU3-NHJ4TUIVnZQ4eE',
  PASSWORD: 'VBHomes2026!',
  NEIGHBORHOODS: [
    'The Bluffs of Brandon',
    'Canterbury Heights',
    'Hazeltine',
    'Heritage Pond',
    'Hitchcock Place — Mitchell',
    'Mapleton Highlands',
    'Mydland Estates',
    'River Park',
    'The Legends at Mapleton',
    'Vistas at Stone Ridge',
    'Westwater at Cherry Lake',
    'Willow Ridge',
    'Other / Out of VBC Development'
  ],
  STATUSES: ['New Inquiry','Active Lead','Proposal Sent','Contract Signed','Build Started','Closed - Won','Closed - Lost','On Hold'],
  LEAD_SOURCES: ['Website','Referral','Parade of Homes','Repeat Customer','Internal','Brandt','Social Media','Sign','Other'],
  SALES_REPS: ['Brandt Williams','Jordan Hefner','Justin Vostad','Outside Realtor','Quentin Robertson','Sydney Van Well'],
  FINANCING: ['VB Homes Financed','Client Financed Build','Cash Build'],
  PROJECT_TYPES: ['Custom Home','Spec Home','Townhome','Addition/Remodel'],
  TEMPS: ['🔥 Hot','☀️ Warm','❄️ Cold'],
  GRADES: ['A','B','C','D'],
  URGENCY: ['Immediate (0-3 mo)','Near-term (3-6 mo)','Mid-range (6-12 mo)','Long-range (12+ mo)','Unknown'],
  COMM_PREFS: ['Phone','Email','Text','Any'],
  CONTRACT_STATUSES: ['Not Started','Sent','Signed'],
  DEPOSIT_STATUSES: ['Not Received','Partial','Received']
};
/* ═══════════════════════════════════════════════════════════════════════════
   WEEKLY PRODUCTION MEETING  (meeting.html)
   ───────────────────────────────────────────────────────────────────────────
   Everything above is unchanged — every page that reads `VBH` behaves exactly
   as before. Everything below is read only by meeting.html, which looks for
   `window.VBH_CONFIG`.

   Keys and password are pulled from the VBH object above rather than repeated,
   so there is still one place to change them.
   ═══════════════════════════════════════════════════════════════════════════ */
window.VBH_CONFIG = {

  password:     VBH.PASSWORD,
  supabaseUrl:  VBH.SUPABASE_URL,
  supabaseAnon: VBH.SUPABASE_KEY,

  /* Drives the header AND every section's time block. Move the meeting and the
     whole agenda shifts with it — 9:00–9:05, 9:05–9:25, and so on. */
  meetingTime: '9:00 – 10:00 AM',

  /* ── MEETING TEAM ────────────────────────────────────────────────────────
     Who sits in the Monday production meeting. Deliberately separate from
     SALES_REPS above — that list includes "Outside Realtor" and people who
     aren't in this meeting.

     name     shows on the agenda and as the Send-panel heading
     email    used for the mailto: draft. Blank = Copy button only, no Email
              button, nothing breaks.
     aliases  what `@name` typing and legacy owner text resolve to. Everyone
              answers to first name, last name, two-letter initials, full name
              and email local part, so an owner cell reading "Vostad", or an old
              string like "JH/SV/JV", still resolves to real people. Sydney also
              answers to the two-word "Van Well" spelling used in SALES_REPS.
              Matching is case-insensitive.
     wins     true = gets a row in the Section 1 round-robin
     ──────────────────────────────────────────────────────────────────────── */
  team: [
    { name:'Dallas',  email:'Dallas.westover@vanbuskirkco.com',   aliases:['dallas', 'westover', 'dw', 'dallas westover', 'dallas.westover'], wins:true  },
    { name:'Jordan',  email:'Jordan.hefner@vanbuskirkco.com',     aliases:['jordan', 'hefner', 'jh', 'jordan hefner', 'jordan.hefner'], wins:true  },
    { name:'Justin',  email:'Justin.vostad@vanbuskirkco.com',     aliases:['justin', 'vostad', 'jv', 'justin vostad', 'justin.vostad'], wins:true  },
    { name:'Kara',    email:'Kara.lilly@vanbuskirkco.com',        aliases:['kara', 'lilly', 'kl', 'kara lilly', 'kara.lilly'], wins:true  },
    { name:'Quentin', email:'Quentin.robertson@vanbuskirkco.com', aliases:['quentin', 'robertson', 'qr', 'quentin robertson', 'quentin.robertson'], wins:true  },
    { name:'Sydney',  email:'Sydney.vanwell@vanbuskirkco.com',    aliases:['sydney', 'vanwell', 'sv', 'sydney vanwell', 'sydney.vanwell', 'van well', 'sydney van well'], wins:true  },
    { name:'Josh',    email:'Josh.Isaacson@vanbuskirkco.com',     aliases:['josh', 'isaacson', 'ji', 'josh isaacson', 'josh.isaacson'], wins:false },
    { name:'Bill',    email:'Bill.hoffman@vanbuskirkco.com',      aliases:['bill', 'hoffman', 'bh', 'bill hoffman', 'bill.hoffman'], wins:false }
  ]
};