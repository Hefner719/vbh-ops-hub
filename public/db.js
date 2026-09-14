// VBH App -- Supabase Database Helper
// Wraps Supabase queries for work orders

let _sbClient = null;

function initDB() {
  if (typeof window.supabase === 'undefined' || !window.supabase.createClient) {
    console.error('Supabase library not loaded yet');
    return false;
  }
  _sbClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  return true;
}

const DB = {
  async create(wo) {
    if (!_sbClient && !initDB()) throw new Error('Database not ready');
    const { data, error } = await _sbClient
      .from('work_orders')
      .insert([wo])
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async fetchAll() {
    if (!_sbClient && !initDB()) throw new Error('Database not ready');
    const { data, error } = await _sbClient
      .from('work_orders')
      .select('*')
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  },

  async update(id, changes) {
    if (!_sbClient && !initDB()) throw new Error('Database not ready');
    const { data, error } = await _sbClient
      .from('work_orders')
      .update(changes)
      .eq('id', id)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async delete(id) {
    if (!_sbClient && !initDB()) throw new Error('Database not ready');
    const { error } = await _sbClient
      .from('work_orders')
      .delete()
      .eq('id', id);
    if (error) throw error;
    return true;
  },

  subscribe(callback) {
    if (!_sbClient && !initDB()) {
      console.error('Cannot subscribe - database not ready');
      return null;
    }
    return _sbClient
      .channel('work_orders_changes')
      .on('postgres_changes',
          { event: '*', schema: 'public', table: 'work_orders' },
          function(payload) { callback(payload); })
      .subscribe();
  }
};

// Try to init immediately if Supabase library is already loaded
if (typeof window !== 'undefined' && window.supabase && window.supabase.createClient) {
  initDB();
}
