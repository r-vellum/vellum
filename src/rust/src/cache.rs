//! A small bounded cache with two-generation ("retain-half") eviction.
//!
//! An LRU approximation that never drops the entire working set at once — unlike
//! a bare `clear()` at capacity, which collapses the hit rate the moment the key
//! space exceeds the cap. Lookups check the *hot* generation, then the *cold*
//! one, promoting a cold hit back to hot. When hot fills to `cap`, it ages to
//! cold and the previous cold is dropped, so at most ~`2*cap` entries stay
//! resident and any working set that fits in `cap` keeps a ~100% hit rate.
//!
//! Callers follow a get-then-insert-on-miss protocol (look up, and only insert a
//! freshly-computed value after a miss), which guarantees a key is never resident
//! in both generations at once.

use std::collections::HashMap;
use std::hash::Hash;

pub struct TwoGenCache<K, V> {
    hot: HashMap<K, V>,
    cold: HashMap<K, V>,
    cap: usize,
}

impl<K: Eq + Hash + Clone, V: Clone> TwoGenCache<K, V> {
    pub fn new(cap: usize) -> Self {
        TwoGenCache { hot: HashMap::new(), cold: HashMap::new(), cap: cap.max(1) }
    }

    /// Look up `k`, promoting a cold hit into the hot generation. Returns a clone
    /// of the value (values are chosen to be cheap to clone — `Rc`, or a `Path`/
    /// `Pixmap` copied exactly as the previous `clear()`-based caches did).
    pub fn get(&mut self, k: &K) -> Option<V> {
        if let Some(v) = self.hot.get(k) {
            return Some(v.clone());
        }
        if let Some(v) = self.cold.remove(k) {
            self.insert(k.clone(), v.clone());
            return Some(v);
        }
        None
    }

    pub fn insert(&mut self, k: K, v: V) {
        if self.hot.len() >= self.cap {
            // Age the hot generation; the previous cold is dropped here.
            self.cold = std::mem::take(&mut self.hot);
        }
        self.hot.insert(k, v);
    }

    pub fn clear(&mut self) {
        self.hot.clear();
        self.cold.clear();
    }

    pub fn len(&self) -> usize {
        self.hot.len() + self.cold.len()
    }
}
