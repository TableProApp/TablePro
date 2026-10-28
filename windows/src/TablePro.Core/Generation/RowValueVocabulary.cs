namespace TablePro.Core.Generation;

/// <summary>
/// The words generated rows are made of. Test data, so it stays the same in every language and never changes between
/// releases: a seed has to keep giving the same rows. The lists are the macOS app's.
/// </summary>
internal static class RowValueVocabulary
{
    public static readonly string[] FirstNames =
    [
        "Aaron", "Abigail", "Adam", "Aiden", "Alice", "Amelia", "Andrew", "Anna", "Benjamin", "Bianca",
        "Caleb", "Camila", "Carlos", "Charlotte", "Chloe", "Daniel", "David", "Diana", "Dylan", "Elena",
        "Elijah", "Ella", "Emily", "Emma", "Ethan", "Eva", "Felix", "Fiona", "Gabriel", "Grace",
        "Hannah", "Henry", "Isaac", "Isabella", "Jack", "James", "Jasmine", "Julia", "Kai", "Laura",
        "Leah", "Leo", "Liam", "Lily", "Lucas", "Lucy", "Maria", "Mason", "Maya", "Mia",
        "Nathan", "Noah", "Nora", "Olivia", "Oscar", "Paul", "Priya", "Quinn", "Rachel", "Ryan",
        "Samuel", "Sara", "Sofia", "Thomas", "Victoria", "William", "Yuki", "Zoe",
    ];

    public static readonly string[] LastNames =
    [
        "Adams", "Allen", "Anderson", "Bailey", "Baker", "Bennett", "Brooks", "Brown", "Campbell", "Carter",
        "Chen", "Clark", "Collins", "Cooper", "Davis", "Diaz", "Edwards", "Evans", "Fischer", "Flores",
        "Garcia", "Gomez", "Gray", "Green", "Hall", "Harris", "Hughes", "Jackson", "Johnson", "Jones",
        "Kim", "King", "Lee", "Lewis", "Lopez", "Martin", "Martinez", "Miller", "Moore", "Morgan",
        "Murphy", "Nguyen", "Novak", "Parker", "Patel", "Perez", "Phillips", "Reed", "Rivera", "Roberts",
        "Rossi", "Sanchez", "Schmidt", "Scott", "Silva", "Smith", "Taylor", "Thomas", "Tran", "Turner",
        "Walker", "Ward", "Watson", "White", "Williams", "Wilson", "Wright", "Young",
    ];

    public static readonly string[] StreetNames =
    [
        "Maple", "Oak", "Pine", "Cedar", "Elm", "Willow", "Birch", "Lake", "Hill", "Park",
        "River", "Sunset", "Highland", "Meadow", "Forest", "Spring", "Church", "Mill", "Main", "Market",
        "Bridge", "Station", "Garden", "Harbor", "Valley", "Ridge", "Orchard", "Union", "Center", "Lincoln",
    ];

    public static readonly string[] StreetSuffixes = ["St", "Ave", "Rd", "Blvd", "Ln", "Way", "Dr", "Ct", "Pl", "Ter"];

    public static readonly string[] Cities =
    [
        "Amsterdam", "Athens", "Austin", "Bangkok", "Barcelona", "Berlin", "Boston", "Brisbane", "Buenos Aires",
        "Cairo", "Cape Town", "Chicago", "Copenhagen", "Dallas", "Denver", "Dublin", "Edinburgh", "Hanoi",
        "Helsinki", "Hong Kong", "Istanbul", "Lisbon", "London", "Los Angeles", "Madrid", "Melbourne",
        "Mexico City", "Milan", "Montreal", "Mumbai", "Munich", "Nairobi", "New York", "Osaka", "Oslo",
        "Paris", "Prague", "Rome", "San Francisco", "Seattle", "Seoul", "Singapore", "Stockholm", "Sydney",
        "Taipei", "Tokyo", "Toronto", "Vancouver", "Vienna", "Warsaw", "Zurich",
    ];

    public static readonly string[] Countries =
    [
        "Argentina", "Australia", "Austria", "Belgium", "Brazil", "Canada", "Chile", "China", "Colombia",
        "Czechia", "Denmark", "Egypt", "Finland", "France", "Germany", "Greece", "India", "Indonesia",
        "Ireland", "Italy", "Japan", "Kenya", "Mexico", "Netherlands", "New Zealand", "Norway", "Poland",
        "Portugal", "Singapore", "South Africa", "South Korea", "Spain", "Sweden", "Switzerland", "Thailand",
        "Turkey", "United Kingdom", "United States", "Vietnam",
    ];

    public static readonly string[] Words =
    [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do",
        "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua", "enim",
        "ad", "minim", "veniam", "quis", "nostrud", "exercitation", "ullamco", "laboris", "nisi", "aliquip",
        "ex", "ea", "commodo", "consequat", "duis", "aute", "irure", "in", "reprehenderit", "voluptate",
        "velit", "esse", "cillum", "fugiat", "nulla", "pariatur", "excepteur", "sint", "occaecat", "cupidatat",
        "non", "proident", "sunt", "culpa", "qui", "officia", "deserunt", "mollit", "anim", "id", "est", "laborum",
    ];

    // RFC 2606 reserves these, so a generated address never reaches a real mailbox.
    public static readonly string[] EmailDomains = ["example.com", "example.net", "example.org"];
}
