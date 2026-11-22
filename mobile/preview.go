package mobile

import "encoding/json"

// PreviewSubscription imports a subscription and returns display data without
// passing connection credentials or the subscription URL to the UI.
func PreviewSubscription(input string, fromURL bool) (string, error) {
	var raw string
	var err error
	if fromURL {
		raw, err = FetchSubscription(input)
	} else {
		raw, err = ImportSubscription([]byte(input))
	}
	if err != nil {
		return "", err
	}
	var imported importedSubscription
	if err := json.Unmarshal([]byte(raw), &imported); err != nil {
		return "", err
	}
	type serverPreview struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		Host     string `json:"host,omitempty"`
		Protocol string `json:"protocol,omitempty"`
		Balance  bool   `json:"balance,omitempty"`
		Missing  bool   `json:"missing,omitempty"`
	}
	preview := struct {
		Title   string          `json:"title,omitempty"`
		Servers []serverPreview `json:"servers"`
	}{Title: imported.Title}
	for _, server := range imported.Servers {
		preview.Servers = append(preview.Servers, serverPreview{
			ID:       server.ID,
			Name:     server.Name,
			Host:     server.Host,
			Protocol: server.Protocol,
			Balance:  server.Balance != nil,
			Missing:  server.Missing,
		})
	}
	data, err := json.Marshal(preview)
	return string(data), err
}
