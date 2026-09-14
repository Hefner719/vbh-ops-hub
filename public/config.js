// VBH App Configuration
// These are PUBLIC keys — safe to expose in client code (anon key is meant for browsers)
const SUPABASE_URL = 'https://bppirsahciuxrqzitfxa.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJwcGlyc2FoY2l1eHJxeml0ZnhhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0MTExMjcsImV4cCI6MjA5NTk4NzEyN30.Yy3en8gNoTPSVkztlGr6XbUq6ZU3-NHJ4TUIVnZQ4eE';

// Jordan's email for notifications
const JORDAN_EMAIL = 'jordan.hefner@vanbuskirkco.com';

// Requestors (used in request form dropdown + completion email lookup)
const REQUESTORS = [
  {name: 'Brandt', email: 'Brandt.williams@vanbuskirkco.com'},
  {name: 'Logan',  email: 'Logan.Callahan@vanbuskirkco.com'},
  {name: 'Gabbie', email: 'Gabbie.hibbert@vanbuskirkco.com'},
  {name: 'Clay',   email: 'Clay.nelson@vanbuskirkco.com'},
  {name: 'Steve',  email: 'Steve@vbclink.com'},
  {name: 'Jordan', email: 'Jordan.hefner@vanbuskirkco.com'},
  {name: 'Kelly',  email: 'Kelly.boyd@vanbuskirkco.com'}
];

// Look up a requestor's email by the name stored on the work order
function requestorEmail(name) {
  if (!name) return '';
  var r = REQUESTORS.find(function(x){ return x.name === name; });
  return r ? r.email : '';
}

// Crew members (used in dashboard approval dropdown)
const CREW = [
  {name: 'Dallas Westover',        email: 'Dallas.westover@vanbuskirkco.com'},
  {name: 'Quentin Robertson',      email: 'Quentin.robertson@vanbuskirkco.com'},
  {name: 'Jordan Hefner - Sub W/O', email: 'Jordan.hefner@vanbuskirkco.com'},
  {name: 'Josh Isaacson',          email: 'Josh.Isaacson@vanbuskirkco.com'},
  {name: 'Jackson Breuer',         email: 'Jackson.Breuer@vanbuskirkco.com'},
  {name: 'Bill Hoffman',           email: 'Bill.hoffman@vanbuskirkco.com'},
  {name: 'Jacob Bender',           email: 'Jacob.bender@vanbuskirkco.com'}
];
