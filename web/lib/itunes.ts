// iTunes Search API client.
// Browser CORS is allowed for iTunes Search API — direct call works.

export interface AppSearchResult {
  id: string; // trackId as string
  name: string;
  iconURL: string;
  category: string;
  sellerName: string;
}

export async function searchApps(query: string): Promise<AppSearchResult[]> {
  const q = encodeURIComponent(query.trim());
  if (!q) return [];
  const res = await fetch(
    `https://itunes.apple.com/search?term=${q}&entity=software&limit=20&country=us`,
  );
  if (!res.ok) throw new Error("Search failed");
  const data = await res.json();
  return (data.results || []).map((item: any) => ({
    id: String(item.trackId),
    name: item.trackName || "",
    iconURL: item.artworkUrl100 || "",
    category: item.primaryGenreName || "",
    sellerName: item.sellerName || "",
  }));
}
