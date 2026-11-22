package mobile

import "encoding/json"

// PreviewSubscription imports a subscription and returns display data without
// passing connection credentials or the subscription URL to the UI.
func PreviewSubscription(input string, fromURL bool) (string, error) {
	raw, err := importInput(input, fromURL)
	if err != nil {
		return "", err
	}
	var imported importedSubscription
	if err := json.Unmarshal([]byte(raw), &imported); err != nil {
		return "", err
	}
	data, err := json.Marshal(previewSubscription("", imported))
	return string(data), err
}

func importInput(input string, fromURL bool) (string, error) {
	if fromURL {
		return FetchSubscription(input)
	}
	return ImportSubscription([]byte(input))
}

type serverPreview struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Host            string `json:"host,omitempty"`
	Protocol        string `json:"protocol,omitempty"`
	Balance         bool   `json:"balance,omitempty"`
	BalanceStrategy string `json:"balanceStrategy,omitempty"`
	Missing         bool   `json:"missing,omitempty"`
}

type subscriptionPreview struct {
	ID         string          `json:"id,omitempty"`
	Title      string          `json:"title,omitempty"`
	Servers    []serverPreview `json:"servers"`
	CanRefresh bool            `json:"canRefresh,omitempty"`
}

func previewSubscription(id string, imported importedSubscription) subscriptionPreview {
	preview := subscriptionPreview{ID: id, Title: imported.Title}
	for _, server := range imported.Servers {
		item := serverPreview{
			ID:       server.ID,
			Name:     server.Name,
			Host:     server.Host,
			Protocol: server.Protocol,
			Balance:  server.Balance != nil,
			Missing:  server.Missing,
		}
		if server.Balance != nil {
			item.BalanceStrategy = server.Balance.StrategyName()
		}
		preview.Servers = append(preview.Servers, item)
	}
	return preview
}
